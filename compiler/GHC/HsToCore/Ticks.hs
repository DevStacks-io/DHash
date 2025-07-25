{-# LANGUAGE NondecreasingIndentation #-}

{-# OPTIONS_GHC -Wno-incomplete-record-updates #-}

{-
(c) Galois, 2006
(c) University of Glasgow, 2007
(c) Florian Ragwitz, 2025
-}

module GHC.HsToCore.Ticks
  ( TicksConfig (..)
  , Tick (..)
  , TickishType (..)
  , addTicksToBinds
  , isGoodSrcSpan'
  , stripTicksTopHsExpr
  ) where

import GHC.Prelude as Prelude

import GHC.Hs
import GHC.Unit

import GHC.Core.Type
import GHC.Core.TyCon

import GHC.Data.Maybe
import GHC.Data.FastString
import GHC.Data.SizedSeq

import GHC.Driver.Flags (DumpFlag(..))

import GHC.Utils.Outputable as Outputable
import GHC.Utils.Panic
import GHC.Utils.Logger
import GHC.Types.SrcLoc
import GHC.Types.Basic
import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Var.Set
import GHC.Types.Var.Env
import GHC.Types.Name.Set hiding (FreeVars)
import GHC.Types.Name
import GHC.Types.CostCentre
import GHC.Types.CostCentre.State
import GHC.Types.Tickish
import GHC.Types.ProfAuto

import Control.Monad
import Data.List (isSuffixOf, intersperse)
import Data.Foldable (toList)

import Trace.Hpc.Mix

import Data.Bifunctor (second)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set (Set)
import qualified Data.Set as Set

{-
************************************************************************
*                                                                      *
*              The main function: addTicksToBinds
*                                                                      *
************************************************************************
-}

-- | Configuration for compilation pass to add tick for instrumentation
-- to binding sites.
data TicksConfig = TicksConfig
  { ticks_passes       :: ![TickishType]
  -- ^ What purposes do we need ticks for

  , ticks_profAuto     :: !ProfAuto
  -- ^ What kind of {-# SCC #-} to add automatically

  , ticks_countEntries :: !Bool
  -- ^ Whether to count the entries to functions
  --
  -- Requires extra synchronization which can vastly degrade
  -- performance.
  }

data Tick = Tick
  { tick_loc   :: SrcSpan   -- ^ Tick source span
  , tick_path  :: [String]  -- ^ Path to the declaration
  , tick_ids   :: [OccName] -- ^ Identifiers being bound
  , tick_label :: BoxLabel  -- ^ Label for the tick counter
  }

addTicksToBinds
        :: Logger
        -> TicksConfig
        -> Module
        -> ModLocation          -- ^ location of the current module
        -> NameSet              -- ^ Exported Ids.  When we call addTicksToBinds,
                                -- isExportedId doesn't work yet (the desugarer
                                -- hasn't set it), so we have to work from this set.
        -> [TyCon]              -- ^ Type constructors in this module
        -> LHsBinds GhcTc
        -> IO (LHsBinds GhcTc, Maybe (FilePath, SizedSeq Tick))

addTicksToBinds logger cfg
                mod mod_loc exports tyCons binds
  | let passes = ticks_passes cfg
  , not (null passes)
  , Just orig_file <- ml_hs_file mod_loc = do

     let  orig_file2 = guessSourceFile binds orig_file

          tickPass tickish (binds,st) =
            let env = TTE
                      { fileName     = mkFastString orig_file2
                      , declPath     = []
                      , tte_countEntries = ticks_countEntries cfg
                      , exports      = exports
                      , inlines      = emptyVarSet
                      , inScope      = emptyVarSet
                      , blackList    = Set.fromList $
                                       mapMaybe (\tyCon -> case getSrcSpan (tyConName tyCon) of
                                                             RealSrcSpan l _ -> Just l
                                                             UnhelpfulSpan _ -> Nothing)
                                                tyCons
                      , density      = mkDensity tickish $ ticks_profAuto cfg
                      , this_mod     = mod
                      , tickishType  = tickish
                      , recSelBinds  = emptyVarEnv
                      }
                (binds',_,st') = unTM (addTickLHsBinds binds) env st
            in (binds', st')

          (binds1,st) = foldr tickPass (binds, initTTState) passes

          extendedMixEntries = ticks st

     putDumpFileMaybe logger Opt_D_dump_ticked "HPC" FormatHaskell
       (pprLHsBinds binds1)

     return (binds1, Just (orig_file2, extendedMixEntries))

  | otherwise = return (binds, Nothing)

guessSourceFile :: LHsBinds GhcTc -> FilePath -> FilePath
guessSourceFile binds orig_file =
     -- Try look for a file generated from a .hsc file to a
     -- .hs file, by peeking ahead.
     let top_pos = catMaybes $ foldr (\ (L pos _) rest ->
                               srcSpanFileName_maybe (locA pos) : rest) [] binds
     in
     case top_pos of
        (file_name:_) | ".hsc" `isSuffixOf` unpackFS file_name
                      -> unpackFS file_name
        _ -> orig_file


-- -----------------------------------------------------------------------------
-- TickDensity

-- | Where to insert ticks
data TickDensity
  = TickForCoverage       -- ^ for Hpc
  | TickForBreakPoints    -- ^ for GHCi
  | TickAllFunctions      -- ^ for -prof-auto-all
  | TickTopFunctions      -- ^ for -prof-auto-top
  | TickExportedFunctions -- ^ for -prof-auto-exported
  | TickCallSites         -- ^ for stack tracing
  deriving Eq

mkDensity :: TickishType -> ProfAuto -> TickDensity
mkDensity tickish pa = case tickish of
  HpcTicks             -> TickForCoverage
  SourceNotes          -> TickForCoverage
  Breakpoints          -> TickForBreakPoints
  ProfNotes ->
    case pa of
      ProfAutoAll      -> TickAllFunctions
      ProfAutoTop      -> TickTopFunctions
      ProfAutoExports  -> TickExportedFunctions
      ProfAutoCalls    -> TickCallSites
      _other           -> panic "mkDensity"

-- | Decide whether to add a tick to a binding or not.
shouldTickBind  :: TickDensity
                -> Bool         -- ^ top level?
                -> Bool         -- ^ exported?
                -> Bool         -- ^ simple pat bind?
                -> Bool         -- ^ INLINE pragma?
                -> Bool

shouldTickBind density top_lev exported _simple_pat inline
 = case density of
      TickForBreakPoints    -> False
        -- we never add breakpoints to simple pattern bindings
        -- (there's always a tick on the rhs anyway).
      TickAllFunctions      -> not inline
      TickTopFunctions      -> top_lev && not inline
      TickExportedFunctions -> exported && not inline
      TickForCoverage       -> True
      TickCallSites         -> False

shouldTickPatBind :: TickDensity -> Bool -> Bool
shouldTickPatBind density top_lev
  = case density of
      TickForBreakPoints    -> False
      TickAllFunctions      -> True
      TickTopFunctions      -> top_lev
      TickExportedFunctions -> False
      TickForCoverage       -> False
      TickCallSites         -> False

-- Strip ticks HsExpr

-- | Strip CoreTicks from an HsExpr
stripTicksTopHsExpr :: HsExpr GhcTc -> ([CoreTickish], HsExpr GhcTc)
stripTicksTopHsExpr (XExpr (HsTick t e)) = let (ts, body) = stripTicksTopHsExpr (unLoc e)
                                            in (t:ts, body)
stripTicksTopHsExpr e = ([], e)

-- -----------------------------------------------------------------------------
-- Adding ticks to bindings

addTickLHsBinds :: LHsBinds GhcTc -> TM (LHsBinds GhcTc)
addTickLHsBinds = mapM addTickLHsBind

addTickLHsBind :: LHsBind GhcTc -> TM (LHsBind GhcTc)
addTickLHsBind (L pos (XHsBindsLR bind@(AbsBinds { abs_binds = binds
                                                 , abs_exports = abs_exports
                                                 }))) =
  withEnv (add_rec_sels . add_inlines . add_exports) $ do
      binds' <- addTickLHsBinds binds
      return $ L pos $ XHsBindsLR $ bind { abs_binds = binds' }
  where
   -- in AbsBinds, the Id on each binding is not the actual top-level
   -- Id that we are defining, they are related by the abs_exports
   -- field of AbsBinds.  So if we're doing TickExportedFunctions we need
   -- to add the local Ids to the set of exported Names so that we know to
   -- tick the right bindings.
   add_exports env =
     env{ exports = exports env `extendNameSetList`
                      [ idName mid
                      | ABE{ abe_poly = pid, abe_mono = mid } <- abs_exports
                      , idName pid `elemNameSet` (exports env) ] }

   -- See Note [inline sccs]
   add_inlines env =
     env{ inlines = inlines env `extendVarSetList`
                      [ mid
                      | ABE{ abe_poly = pid, abe_mono = mid } <- abs_exports
                      , isInlinePragma (idInlinePragma pid) ] }

   add_rec_sels env =
     env{ recSelBinds = recSelBinds env `extendVarEnvList`
                          [ (abe_mono, abe_poly)
                          | ABE{ abe_poly, abe_mono } <- abs_exports
                          , RecSelId{} <- [idDetails abe_poly] ] }

addTickLHsBind (L pos (funBind@(FunBind { fun_id = L _ id, fun_matches = matches }))) = do
  let name = getOccString id
  decl_path <- getPathEntry
  density <- getDensity

  inline_ids <- liftM inlines getEnv
  -- See Note [inline sccs]
  let inline   = isInlinePragma (idInlinePragma id)
                 || id `elemVarSet` inline_ids

  -- See Note [inline sccs]
  tickish <- tickishType `liftM` getEnv
  case tickish of { ProfNotes | inline -> return (L pos funBind); _ -> do

  -- See Note [Record-selector ticks]
  selTick <- recSelTick id
  case selTick of { Just tick -> tick_rec_sel tick; _ -> do

  (fvs, mg) <-
        getFreeVars $
        addPathEntry name $
        addTickMatchGroup False matches

  blackListed <- isBlackListed (locA pos)
  exported_names <- liftM exports getEnv

  -- We don't want to generate code for blacklisted positions
  -- We don't want redundant ticks on simple pattern bindings
  -- We don't want to tick non-exported bindings in TickExportedFunctions
  let simple = matchGroupArity matches == 0
                  -- A binding is a "simple pattern binding" if it is a
                  -- funbind with zero patterns
      toplev = null decl_path
      exported = idName id `elemNameSet` exported_names

  tick <- if not blackListed &&
               shouldTickBind density toplev exported simple inline
             then
                bindTick density name (locA pos) fvs
             else
                return Nothing

  let mbCons = maybe Prelude.id (:)
  return $ L pos $ funBind { fun_matches = mg
                           , fun_ext = second (tick `mbCons`) (fun_ext funBind) }
  } }
  where
    -- See Note [Record-selector ticks]
    tick_rec_sel tick =
      pure $ L pos $ funBind { fun_ext = second (tick :) (fun_ext funBind) }


-- Note [Record-selector ticks]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Users expect (see #17834) that accessing a record field by its name using
-- NamedFieldPuns or RecordWildCards will mark it as covered. This is very
-- reasonable, because otherwise the use of those two language features will
-- produce unnecessary noise in coverage reports, distracting from real
-- coverage problems.
--
-- Because of that, GHC chooses to treat record selectors specially for
-- coverage purposes to improve the developer experience.
--
-- This is done by keeping track of which 'Id's are effectively bound to
-- record fields (using NamedFieldPuns or RecordWildCards) in 'TickTransEnv's
-- 'recSelBinds', and making 'HsVar's corresponding to those fields tick the
-- appropriate box when executed.
--
-- To enable that, we also treat 'FunBind's for record selector functions
-- specially. We only create a TopLevelBox for the record selector function,
-- skipping the ExpBox that'd normally be created. This simplifies the re-use
-- of ticks for the same record selector, and is done by not recursing into
-- the fun_matches match group for record selector functions.
--
-- This scheme could be extended further in the future, making coverage for
-- constructor fields (named or even positional) mean that the field was
-- accessed at run-time. For the time being, we only cover NamedFieldPuns and
-- RecordWildCards binds to cover most practical use-cases while keeping it
-- simple.

-- TODO: Revisit this
addTickLHsBind (L pos (pat@(PatBind { pat_lhs = lhs
                                    , pat_rhs = rhs
                                    , pat_ext = (grhs_ty, initial_ticks)}))) = do

  let simplePatId = isSimplePat lhs

  -- TODO: better name for rhs's for non-simple patterns?
  let name = maybe "(...)" getOccString simplePatId

  (fvs, rhs') <- getFreeVars $ addPathEntry name $ addTickGRHSs False False False rhs
  let pat' = pat { pat_rhs = rhs'}

  -- Should create ticks here?
  density <- getDensity
  decl_path <- getPathEntry
  let top_lev = null decl_path
  if not (shouldTickPatBind density top_lev)
    then return (L pos pat')
    else do

    -- Allocate the ticks
    rhs_tick <- bindTick density name (locA pos) fvs

    let mbCons = maybe id (:)
        (initial_rhs_ticks, initial_patvar_tickss) = initial_ticks
        rhs_ticks = rhs_tick `mbCons` initial_rhs_ticks

    patvar_tickss <- case simplePatId of
      Just{} -> return initial_patvar_tickss
      Nothing -> do
        let patvars = map getOccString (collectPatBinders CollNoDictBinders lhs)
        patvar_ticks <- mapM (\v -> bindTick density v (locA pos) fvs) patvars
        return
          (zipWith mbCons patvar_ticks
                          (initial_patvar_tickss ++ repeat []))

    return $ L pos $ pat' { pat_ext = (grhs_ty, (rhs_ticks, patvar_tickss)) }

-- Only internal stuff, not from source, uses VarBind, so we ignore it.
addTickLHsBind var_bind@(L _ (VarBind {})) = return var_bind
addTickLHsBind patsyn_bind@(L _ (PatSynBind {})) = return patsyn_bind

bindTick
  :: TickDensity -> String -> SrcSpan -> FreeVars -> TM (Maybe CoreTickish)
bindTick density name pos fvs = do
  decl_path <- getPathEntry
  let
      toplev        = null decl_path
      count_entries = toplev || density == TickAllFunctions
      top_only      = density /= TickAllFunctions
      box_label     = if toplev then TopLevelBox [name]
                                else LocalBox (decl_path ++ [name])
  --
  allocATickBox box_label count_entries top_only pos fvs


-- Note [inline sccs]
-- ~~~~~~~~~~~~~~~~~~
-- The reason not to add ticks to INLINE functions is that this is
-- sometimes handy for avoiding adding a tick to a particular function
-- (see #6131)
--
-- So for now we do not add any ticks to INLINE functions at all.
--
-- We used to use isAnyInlinePragma to figure out whether to avoid adding
-- ticks for this purpose. However, #12962 indicates that this contradicts
-- the documentation on profiling (which only mentions INLINE pragmas).
-- So now we're more careful about what we avoid adding ticks to.

-- -----------------------------------------------------------------------------
-- Decorate an LHsExpr with ticks

-- selectively add ticks to interesting expressions
addTickLHsExpr :: LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExpr e@(L pos e0) = do
  d <- getDensity
  case d of
    TickForBreakPoints | isGoodBreakExpr e0 -> tick_it
    TickForCoverage    | XExpr (ExpandedThingTc OrigStmt{} _) <- e0 -- expansion ticks are handled separately
                       -> dont_tick_it
                       | otherwise -> tick_it
    TickCallSites      | isCallSite e0      -> tick_it
    _other             -> dont_tick_it
 where
   tick_it      = allocTickBox (ExpBox False) False False (locA pos)
                  $ addTickHsExpr e0
   dont_tick_it = addTickLHsExprNever e

-- Add a tick to an expression which is the RHS of an equation or a binding.
-- We always consider these to be breakpoints, unless the expression is a 'let'
-- (because the body will definitely have a tick somewhere).  ToDo: perhaps
-- we should treat 'case' and 'if' the same way?
addTickLHsExprRHS :: LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExprRHS e@(L pos e0) = do
  d <- getDensity
  case d of
     TickForBreakPoints | HsLet{} <- e0 -> dont_tick_it
                        | otherwise     -> tick_it
     TickForCoverage -> tick_it
     TickCallSites   | isCallSite e0 -> tick_it
     _other          -> dont_tick_it
 where
   tick_it      = allocTickBox (ExpBox False) False False (locA pos)
                  $ addTickHsExpr e0
   dont_tick_it = addTickLHsExprNever e

-- The inner expression of an evaluation context:
--    let binds in [], ( [] )
-- we never tick these if we're doing HPC, but otherwise
-- we treat it like an ordinary expression.
addTickLHsExprEvalInner :: LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExprEvalInner e = do
   d <- getDensity
   case d of
     TickForCoverage -> addTickLHsExprNever e
     _otherwise      -> addTickLHsExpr e

-- | A let body is treated differently from addTickLHsExprEvalInner
-- above with TickForBreakPoints, because for breakpoints we always
-- want to tick the body, even if it is not a redex.  See test
-- break012.  This gives the user the opportunity to inspect the
-- values of the let-bound variables.
addTickLHsExprLetBody :: LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExprLetBody e@(L pos e0) = do
  d <- getDensity
  case d of
     TickForBreakPoints | HsLet{} <- e0 -> dont_tick_it
                        | otherwise     -> tick_it
     _other -> addTickLHsExprEvalInner e
 where
   tick_it      = allocTickBox (ExpBox False) False False (locA pos)
                  -- don't allow duplicates of this forced bp
                  $ withBlackListed (locA pos)
                  $ addTickHsExpr e0
   dont_tick_it = addTickLHsExprNever e

-- version of addTick that does not actually add a tick,
-- because the scope of this tick is completely subsumed by
-- another.
addTickLHsExprNever :: LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExprNever (L pos e0) = do
    e1 <- addTickHsExpr e0
    return $ L pos e1

-- General heuristic: expressions which are calls (do not denote
-- values) are good break points.
isGoodBreakExpr :: HsExpr GhcTc -> Bool
isGoodBreakExpr (XExpr (ExpandedThingTc (OrigStmt{}) _)) = False
isGoodBreakExpr e = isCallSite e

isCallSite :: HsExpr GhcTc -> Bool
isCallSite HsApp{}     = True
isCallSite HsAppType{} = True
isCallSite HsCase{}    = True
isCallSite (XExpr (ExpandedThingTc _ e))
  = isCallSite e

-- NB: OpApp, SectionL, SectionR are all expanded out
isCallSite _           = False

addTickLHsExprOptAlt :: Bool -> LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickLHsExprOptAlt oneOfMany e@(L pos e0)
  = ifDensity TickForCoverage
        (allocTickBox (ExpBox oneOfMany) False False (locA pos)
                           $ addTickHsExpr e0)
        (addTickLHsExpr e)

addBinTickLHsExpr :: (Bool -> BoxLabel) -> LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addBinTickLHsExpr boxLabel e@(L pos e0)
  = ifDensity TickForCoverage
        (allocBinTickBox boxLabel (locA pos) $ addTickHsExpr e0)
        (addTickLHsExpr e)


-- -----------------------------------------------------------------------------
-- Decorate the body of an HsExpr with ticks.
-- (Whether to put a tick around the whole expression was already decided,
-- in the addTickLHsExpr family of functions.)

addTickHsExpr :: HsExpr GhcTc -> TM (HsExpr GhcTc)
-- See Note [Record-selector ticks]
addTickHsExpr e@(HsVar _ (L _ id)) =
    freeVar id >> recSelTick id >>= pure . maybe e wrap
  where wrap tick = XExpr . HsTick tick . noLocA $ e
addTickHsExpr e@(HsIPVar {})            = return e
addTickHsExpr e@(HsOverLit {})          = return e
addTickHsExpr e@(HsOverLabel{})         = return e
addTickHsExpr e@(HsLit {})              = return e
addTickHsExpr e@(HsEmbTy {})            = return e
addTickHsExpr e@(HsHole {})             = return e
addTickHsExpr e@(HsQual {})             = return e
addTickHsExpr e@(HsForAll {})           = return e
addTickHsExpr e@(HsFunArr {})           = return e
addTickHsExpr (HsLam x v mg)            = liftM (HsLam x v)
                                                (addTickMatchGroup True mg)
addTickHsExpr (HsApp x e1 e2)          = liftM2 (HsApp x) (addTickLHsExprNever e1)
                                                          (addTickLHsExpr      e2)
addTickHsExpr (HsAppType x e ty) = do
        e' <- addTickLHsExprNever e
        return (HsAppType x e' ty)
addTickHsExpr (OpApp fix e1 e2 e3) =
        liftM4 OpApp
                (return fix)
                (addTickLHsExpr e1)
                (addTickLHsExprNever e2)
                (addTickLHsExpr e3)
addTickHsExpr (NegApp x e neg) =
        liftM2 (NegApp x)
                (addTickLHsExpr e)
                (addTickSyntaxExpr hpcSrcSpan neg)
addTickHsExpr (HsPar x e) = do
        e' <- addTickLHsExprEvalInner e
        return (HsPar x e')
addTickHsExpr (SectionL x e1 e2) =
        liftM2 (SectionL x)
                (addTickLHsExpr e1)
                (addTickLHsExprNever e2)
addTickHsExpr (SectionR x e1 e2) =
        liftM2 (SectionR x)
                (addTickLHsExprNever e1)
                (addTickLHsExpr e2)
addTickHsExpr (ExplicitTuple x es boxity) =
        liftM2 (ExplicitTuple x)
                (mapM addTickTupArg es)
                (return boxity)
addTickHsExpr (ExplicitSum ty tag arity e) = do
        e' <- addTickLHsExpr e
        return (ExplicitSum ty tag arity e')
addTickHsExpr (HsCase x e mgs) =
        liftM2 (HsCase x)
                (addTickLHsExpr e) -- not an EvalInner; e might not necessarily
                                   -- be evaluated.
                (addTickMatchGroup False mgs)

addTickHsExpr (HsIf x e1 e2 e3) =
        liftM3 (HsIf x)
                (addBinTickLHsExpr (BinBox CondBinBox) e1)
                (addTickLHsExprOptAlt True e2)
                (addTickLHsExprOptAlt True e3)
addTickHsExpr (HsMultiIf ty alts)
  = do { let isOneOfMany = case alts of { (_ :| []) -> False; _ -> True; }
       ; alts' <- mapM (traverse $ addTickGRHS isOneOfMany False False) alts
       ; return $ HsMultiIf ty alts' }
addTickHsExpr (HsLet x binds e) =
        bindLocals binds $ do
          binds' <- addTickHsLocalBinds binds -- to think about: !patterns.
          e' <- addTickLHsExprLetBody e
          return (HsLet x binds' e')
addTickHsExpr (ExplicitList ty es)
  = liftM2 ExplicitList (return ty) (mapM (addTickLHsExpr) es)

addTickHsExpr (HsStatic fvs e) = HsStatic fvs <$> addTickLHsExpr e

addTickHsExpr expr@(RecordCon { rcon_flds = rec_binds })
  = do { rec_binds' <- addTickHsRecordBinds rec_binds
       ; return (expr { rcon_flds = rec_binds' }) }

addTickHsExpr expr@(RecordUpd { rupd_expr = e
                              , rupd_flds = upd@(RegularRecUpdFields { recUpdFields = flds }) })
  = do { e' <- addTickLHsExpr e
       ; flds' <- mapM addTickHsRecField flds
       ; return (expr { rupd_expr = e', rupd_flds = upd { recUpdFields = flds' } }) }
addTickHsExpr expr@(RecordUpd { rupd_expr = e
                              , rupd_flds = upd@(OverloadedRecUpdFields { olRecUpdFields = flds } ) })
  = do { e' <- addTickLHsExpr e
       ; flds' <- mapM addTickHsRecField flds
       ; return (expr { rupd_expr = e', rupd_flds = upd { olRecUpdFields = flds' } }) }

addTickHsExpr (ExprWithTySig x e ty) =
        liftM3 ExprWithTySig
                (return x)
                (addTickLHsExprNever e) -- No need to tick the inner expression
                                        -- for expressions with signatures
                (return ty)
addTickHsExpr (ArithSeq ty wit arith_seq) =
        liftM3 ArithSeq
                (return ty)
                (addTickWit wit)
                (addTickArithSeqInfo arith_seq)
             where addTickWit Nothing = return Nothing
                   addTickWit (Just fl) = do fl' <- addTickSyntaxExpr hpcSrcSpan fl
                                             return (Just fl')

addTickHsExpr (HsPragE x p e) =
        liftM (HsPragE x p) (addTickLHsExpr e)
addTickHsExpr e@(HsTypedBracket {})  = return e
addTickHsExpr e@(HsUntypedBracket{}) = return e
addTickHsExpr e@(HsTypedSplice{})    = return e
addTickHsExpr e@(HsUntypedSplice{})  = return e
addTickHsExpr e@(HsGetField {})      = return e
addTickHsExpr e@(HsProjection {})    = return e
addTickHsExpr (HsProc x pat cmdtop) =
      bindLocals pat $
        liftM2 (HsProc x)
                (addTickLPat pat)
                (traverse (addTickHsCmdTop) cmdtop)
addTickHsExpr (XExpr (WrapExpr w e)) =
        liftM (XExpr . WrapExpr w) $
              (addTickHsExpr e)        -- Explicitly no tick on inside
addTickHsExpr (XExpr (ExpandedThingTc o e)) = addTickHsExpanded o e

addTickHsExpr e@(XExpr (ConLikeTc {})) = return e
  -- We used to do a freeVar on a pat-syn builder, but actually
  -- such builders are never in the inScope env, which
  -- doesn't include top level bindings

-- We might encounter existing ticks (multiple Coverage passes)
addTickHsExpr (XExpr (HsTick t e)) =
        liftM (XExpr . HsTick t) (addTickLHsExprNever e)
addTickHsExpr (XExpr (HsBinTick t0 t1 e)) =
        liftM (XExpr . HsBinTick t0 t1) (addTickLHsExprNever e)

addTickHsExpr e@(XExpr (HsRecSelTc (FieldOcc _ id)))   = do freeVar (unLoc id); return e

addTickHsExpr (HsDo srcloc cxt (L l stmts))
  = do { (stmts', _) <- addTickLStmts' forQual stmts (return ())
       ; return (HsDo srcloc cxt (L l stmts')) }
  where
        forQual = case cxt of
                    ListComp -> Just $ BinBox QualBinBox
                    _        -> Nothing

addTickHsExpanded :: HsThingRn -> HsExpr GhcTc -> TM (HsExpr GhcTc)
addTickHsExpanded o e = liftM (XExpr . ExpandedThingTc o) $ case o of
  -- We always want statements to get a tick, so we can step over each one.
  -- To avoid duplicates we blacklist SrcSpans we already inserted here.
  OrigStmt (L pos _) -> do_tick_black pos
  _                  -> skip
  where
    skip = addTickHsExpr e
    do_tick_black pos = do
      d <- getDensity
      case d of
         TickForCoverage    -> tick_it_black pos
         TickForBreakPoints -> tick_it_black pos
         _                  -> skip
    tick_it_black pos =
      unLoc <$> allocTickBox (ExpBox False) False False (locA pos)
                             (withBlackListed (locA pos) $
                               addTickHsExpr e)

addTickTupArg :: HsTupArg GhcTc -> TM (HsTupArg GhcTc)
addTickTupArg (Present x e)  = do { e' <- addTickLHsExpr e
                                  ; return (Present x e') }
addTickTupArg (Missing ty) = return (Missing ty)


addTickMatchGroup :: Bool{-is lambda-} -> MatchGroup GhcTc (LHsExpr GhcTc)
                  -> TM (MatchGroup GhcTc (LHsExpr GhcTc))
addTickMatchGroup is_lam mg@(MG { mg_alts = L l matches, mg_ext = ctxt }) = do
  let isOneOfMany = matchesOneOfMany matches
      isDoExp     = isDoExpansionGenerated $ mg_origin ctxt
  matches' <- mapM (traverse (addTickMatch isOneOfMany is_lam isDoExp)) matches
  return $ mg { mg_alts = L l matches' }

addTickMatch :: Bool -> Bool -> Bool {-Is this Do Expansion-} ->  Match GhcTc (LHsExpr GhcTc)
             -> TM (Match GhcTc (LHsExpr GhcTc))
addTickMatch isOneOfMany isLambda isDoExp match@(Match { m_pats = L _ pats
                                                       , m_grhss = gRHSs }) =
  bindLocals pats $ do
    gRHSs' <- addTickGRHSs isOneOfMany isLambda isDoExp gRHSs
    return $ match { m_grhss = gRHSs' }

addTickGRHSs :: Bool -> Bool -> Bool -> GRHSs GhcTc (LHsExpr GhcTc)
             -> TM (GRHSs GhcTc (LHsExpr GhcTc))
addTickGRHSs isOneOfMany isLambda isDoExp (GRHSs x guarded local_binds) =
  bindLocals local_binds $ do
    local_binds' <- addTickHsLocalBinds local_binds
    guarded' <- mapM (traverse (addTickGRHS isOneOfMany isLambda isDoExp)) guarded
    return $ GRHSs x guarded' local_binds'

addTickGRHS :: Bool -> Bool -> Bool -> GRHS GhcTc (LHsExpr GhcTc)
            -> TM (GRHS GhcTc (LHsExpr GhcTc))
addTickGRHS isOneOfMany isLambda isDoExp (GRHS x stmts expr) = do
  (stmts',expr') <- addTickLStmts' (Just $ BinBox $ GuardBinBox) stmts
                        (addTickGRHSBody isOneOfMany isLambda isDoExp expr)
  return $ GRHS x stmts' expr'

addTickGRHSBody :: Bool -> Bool -> Bool -> LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTickGRHSBody isOneOfMany isLambda isDoExp expr@(L pos e0) = do
  d <- getDensity
  case d of
    TickForBreakPoints
      | isDoExp       -- ticks for do-expansions are handled by `addTickHsExpanded`
      -> addTickLHsExprNever expr
      | otherwise
      -> addTickLHsExprRHS expr
    TickForCoverage
      | isDoExp       -- ticks for do-expansions are handled by `addTickHsExpanded`
      -> addTickLHsExprNever expr
      | otherwise
      -> addTickLHsExprOptAlt isOneOfMany expr
    TickAllFunctions | isLambda ->
       addPathEntry "\\" $
         allocTickBox (ExpBox False) True{-count-} False{-not top-} (locA pos) $
           addTickHsExpr e0
    _otherwise ->
       addTickLHsExprRHS expr

addTickLStmts :: (Maybe (Bool -> BoxLabel)) -> [ExprLStmt GhcTc]
              -> TM [ExprLStmt GhcTc]
addTickLStmts isGuard stmts = do
  (stmts, _) <- addTickLStmts' isGuard stmts (return ())
  return stmts

addTickLStmts' :: (Maybe (Bool -> BoxLabel)) -> [ExprLStmt GhcTc] -> TM a
               -> TM ([ExprLStmt GhcTc], a)
addTickLStmts' isGuard lstmts res
  = bindLocals lstmts $
    do { lstmts' <- mapM (traverse (addTickStmt isGuard)) lstmts
       ; a <- res
       ; return (lstmts', a) }

addTickStmt :: (Maybe (Bool -> BoxLabel)) -> Stmt GhcTc (LHsExpr GhcTc)
            -> TM (Stmt GhcTc (LHsExpr GhcTc))
addTickStmt _isGuard (LastStmt x e noret ret) =
        liftM3 (LastStmt x)
                (addTickLHsExpr e)
                (pure noret)
                (addTickSyntaxExpr hpcSrcSpan ret)
addTickStmt _isGuard (BindStmt xbs pat e) =
      bindLocals pat $
        liftM4 (\b f -> BindStmt $ XBindStmtTc
                    { xbstc_bindOp = b
                    , xbstc_boundResultType = xbstc_boundResultType xbs
                    , xbstc_boundResultMult = xbstc_boundResultMult xbs
                    , xbstc_failOp = f
                    })
                (addTickSyntaxExpr hpcSrcSpan (xbstc_bindOp xbs))
                (mapM (addTickSyntaxExpr hpcSrcSpan) (xbstc_failOp xbs))
                (addTickLPat pat)
                (addTickLHsExprRHS e)
addTickStmt isGuard (BodyStmt x e bind' guard') =
        liftM3 (BodyStmt x)
                (addTick isGuard e)
                (addTickSyntaxExpr hpcSrcSpan bind')
                (addTickSyntaxExpr hpcSrcSpan guard')
addTickStmt _isGuard (LetStmt x binds) =
        liftM (LetStmt x)
                (addTickHsLocalBinds binds)
addTickStmt isGuard (ParStmt x pairs mzipExpr bindExpr) =
    liftM3 (ParStmt x)
        (mapM (addTickStmtAndBinders isGuard) pairs)
        (unLoc <$> addTickLHsExpr (L (noAnnSrcSpan hpcSrcSpan) mzipExpr))
        (addTickSyntaxExpr hpcSrcSpan bindExpr)

addTickStmt isGuard stmt@(TransStmt { trS_stmts = stmts
                                    , trS_by = by, trS_using = using
                                    , trS_ret = returnExpr, trS_bind = bindExpr
                                    , trS_fmap = liftMExpr }) = do
    t_s <- addTickLStmts isGuard stmts
    t_y <- traverse  addTickLHsExprRHS by
    t_u <- addTickLHsExprRHS using
    t_f <- addTickSyntaxExpr hpcSrcSpan returnExpr
    t_b <- addTickSyntaxExpr hpcSrcSpan bindExpr
    t_m <- fmap unLoc (addTickLHsExpr (L (noAnnSrcSpan hpcSrcSpan) liftMExpr))
    return $ stmt { trS_stmts = t_s, trS_by = t_y, trS_using = t_u
                  , trS_ret = t_f, trS_bind = t_b, trS_fmap = t_m }

addTickStmt isGuard stmt@(RecStmt {})
  = do { stmts' <- addTickLStmts isGuard (unLoc $ recS_stmts stmt)
       ; ret'   <- addTickSyntaxExpr hpcSrcSpan (recS_ret_fn stmt)
       ; mfix'  <- addTickSyntaxExpr hpcSrcSpan (recS_mfix_fn stmt)
       ; bind'  <- addTickSyntaxExpr hpcSrcSpan (recS_bind_fn stmt)
       ; return (stmt { recS_stmts = noLocA stmts', recS_ret_fn = ret'
                      , recS_mfix_fn = mfix', recS_bind_fn = bind' }) }

addTickStmt isGuard (XStmtLR (ApplicativeStmt body_ty args mb_join)) = do
    args' <- mapM (addTickApplicativeArg isGuard) args
    return (XStmtLR (ApplicativeStmt body_ty args' mb_join))

addTick :: Maybe (Bool -> BoxLabel) -> LHsExpr GhcTc -> TM (LHsExpr GhcTc)
addTick isGuard e | Just fn <- isGuard = addBinTickLHsExpr fn e
                  | otherwise          = addTickLHsExprRHS e

addTickApplicativeArg
  :: Maybe (Bool -> BoxLabel) -> (SyntaxExpr GhcTc, ApplicativeArg GhcTc)
  -> TM (SyntaxExpr GhcTc, ApplicativeArg GhcTc)
addTickApplicativeArg isGuard (op, arg) =
  liftM2 (,) (addTickSyntaxExpr hpcSrcSpan op) (addTickArg arg)
 where
  addTickArg (ApplicativeArgOne m_fail pat expr isBody) =
    bindLocals pat $
      ApplicativeArgOne
        <$> mapM (addTickSyntaxExpr hpcSrcSpan) m_fail
        <*> addTickLPat pat
        <*> addTickLHsExpr expr
        <*> pure isBody
  addTickArg (ApplicativeArgMany x stmts ret pat ctxt) =
    bindLocals pat $
      ApplicativeArgMany x
        <$> addTickLStmts isGuard stmts
        <*> (unLoc <$> addTickLHsExpr (L (noAnnSrcSpan hpcSrcSpan) ret))
        <*> addTickLPat pat
        <*> pure ctxt

addTickStmtAndBinders :: Maybe (Bool -> BoxLabel) -> ParStmtBlock GhcTc GhcTc
                      -> TM (ParStmtBlock GhcTc GhcTc)
addTickStmtAndBinders isGuard (ParStmtBlock x stmts ids returnExpr) =
    liftM3 (ParStmtBlock x)
        (addTickLStmts isGuard stmts)
        (return ids)
        (addTickSyntaxExpr hpcSrcSpan returnExpr)

addTickHsLocalBinds :: HsLocalBinds GhcTc -> TM (HsLocalBinds GhcTc)
addTickHsLocalBinds (HsValBinds x binds) =
        liftM (HsValBinds x)
                (addTickHsValBinds binds)
addTickHsLocalBinds (HsIPBinds x binds)  =
        liftM (HsIPBinds x)
                (addTickHsIPBinds binds)
addTickHsLocalBinds (EmptyLocalBinds x)  = return (EmptyLocalBinds x)

addTickHsValBinds :: HsValBindsLR GhcTc (GhcPass a)
                  -> TM (HsValBindsLR GhcTc (GhcPass b))
addTickHsValBinds (XValBindsLR (NValBinds binds sigs)) = do
        b <- liftM2 NValBinds
                (mapM (\ (rec,binds') ->
                                liftM2 (,)
                                        (return rec)
                                        (addTickLHsBinds binds'))
                        binds)
                (return sigs)
        return $ XValBindsLR b
addTickHsValBinds _ = panic "addTickHsValBinds"

addTickHsIPBinds :: HsIPBinds GhcTc -> TM (HsIPBinds GhcTc)
addTickHsIPBinds (IPBinds dictbinds ipbinds) =
        liftM2 IPBinds
                (return dictbinds)
                (mapM (traverse (addTickIPBind)) ipbinds)

addTickIPBind :: IPBind GhcTc -> TM (IPBind GhcTc)
addTickIPBind (IPBind x nm e) =
        liftM (IPBind x nm)
               (addTickLHsExpr e)

-- There is no location here, so we might need to use a context location??
addTickSyntaxExpr :: SrcSpan -> SyntaxExpr GhcTc -> TM (SyntaxExpr GhcTc)
addTickSyntaxExpr pos syn@(SyntaxExprTc { syn_expr = x }) = do
        x' <- fmap unLoc (addTickLHsExpr (L (noAnnSrcSpan pos) x))
        return $ syn { syn_expr = x' }
addTickSyntaxExpr _ NoSyntaxExprTc = return NoSyntaxExprTc

-- we do not walk into patterns.
addTickLPat :: LPat GhcTc -> TM (LPat GhcTc)
addTickLPat pat = return pat

addTickHsCmdTop :: HsCmdTop GhcTc -> TM (HsCmdTop GhcTc)
addTickHsCmdTop (HsCmdTop x cmd) =
        liftM2 HsCmdTop
                (return x)
                (addTickLHsCmd cmd)

addTickLHsCmd ::  LHsCmd GhcTc -> TM (LHsCmd GhcTc)
addTickLHsCmd (L pos c0) = do
        c1 <- addTickHsCmd c0
        return $ L pos c1

addTickHsCmd :: HsCmd GhcTc -> TM (HsCmd GhcTc)
addTickHsCmd (HsCmdLam x lam_variant mgs) =
        liftM (HsCmdLam x lam_variant) (addTickCmdMatchGroup mgs)
addTickHsCmd (HsCmdApp x c e) =
        liftM2 (HsCmdApp x) (addTickLHsCmd c) (addTickLHsExpr e)
{-
addTickHsCmd (OpApp e1 c2 fix c3) =
        liftM4 OpApp
                (addTickLHsExpr e1)
                (addTickLHsCmd c2)
                (return fix)
                (addTickLHsCmd c3)
-}
addTickHsCmd (HsCmdPar x e) = do
        e' <- addTickLHsCmd e
        return (HsCmdPar x e')
addTickHsCmd (HsCmdCase x e mgs) =
        liftM2 (HsCmdCase x)
                (addTickLHsExpr e)
                (addTickCmdMatchGroup mgs)
addTickHsCmd (HsCmdIf x cnd e1 c2 c3) =
        liftM3 (HsCmdIf x cnd)
                (addBinTickLHsExpr (BinBox CondBinBox) e1)
                (addTickLHsCmd c2)
                (addTickLHsCmd c3)
addTickHsCmd (HsCmdLet x binds c) =
        bindLocals binds $ do
          binds' <- addTickHsLocalBinds binds -- to think about: !patterns.
          c' <- addTickLHsCmd c
          return (HsCmdLet x binds' c')
addTickHsCmd (HsCmdDo srcloc (L l stmts))
  = do { (stmts', _) <- addTickLCmdStmts' stmts (return ())
       ; return (HsCmdDo srcloc (L l stmts')) }

addTickHsCmd (HsCmdArrApp  arr_ty e1 e2 ty1 lr) =
        liftM5 HsCmdArrApp
               (return arr_ty)
               (addTickLHsExpr e1)
               (addTickLHsExpr e2)
               (return ty1)
               (return lr)
addTickHsCmd (HsCmdArrForm x e f cmdtop) =
        liftM3 (HsCmdArrForm x)
               (addTickLHsExpr e)
               (return f)
               (mapM (traverse (addTickHsCmdTop)) cmdtop)

addTickHsCmd (XCmd (HsWrap w cmd)) =
  liftM XCmd $
  liftM (HsWrap w) (addTickHsCmd cmd)

-- Others should never happen in a command context.
--addTickHsCmd e  = pprPanic "addTickHsCmd" (ppr e)

addTickCmdMatchGroup :: MatchGroup GhcTc (LHsCmd GhcTc)
                     -> TM (MatchGroup GhcTc (LHsCmd GhcTc))
addTickCmdMatchGroup mg@(MG { mg_alts = (L l matches) }) = do
  matches' <- mapM (traverse addTickCmdMatch) matches
  return $ mg { mg_alts = L l matches' }

addTickCmdMatch :: Match GhcTc (LHsCmd GhcTc) -> TM (Match GhcTc (LHsCmd GhcTc))
addTickCmdMatch match@(Match { m_pats = L _ pats, m_grhss = gRHSs }) =
  bindLocals pats $ do
    gRHSs' <- addTickCmdGRHSs gRHSs
    return $ match { m_grhss = gRHSs' }

addTickCmdGRHSs :: GRHSs GhcTc (LHsCmd GhcTc) -> TM (GRHSs GhcTc (LHsCmd GhcTc))
addTickCmdGRHSs (GRHSs x guarded local_binds) =
  bindLocals local_binds $ do
    local_binds' <- addTickHsLocalBinds local_binds
    guarded' <- mapM (traverse addTickCmdGRHS) guarded
    return $ GRHSs x guarded' local_binds'

addTickCmdGRHS :: GRHS GhcTc (LHsCmd GhcTc) -> TM (GRHS GhcTc (LHsCmd GhcTc))
-- The *guards* are *not* Cmds, although the body is
-- C.f. addTickGRHS for the BinBox stuff
addTickCmdGRHS (GRHS x stmts cmd)
  = do { (stmts',expr') <- addTickLStmts' (Just $ BinBox $ GuardBinBox)
                                   stmts (addTickLHsCmd cmd)
       ; return $ GRHS x stmts' expr' }

addTickLCmdStmts :: [LStmt GhcTc (LHsCmd GhcTc)]
                 -> TM [LStmt GhcTc (LHsCmd GhcTc)]
addTickLCmdStmts stmts = do
  (stmts, _) <- addTickLCmdStmts' stmts (return ())
  return stmts

addTickLCmdStmts' :: [LStmt GhcTc (LHsCmd GhcTc)] -> TM a
                  -> TM ([LStmt GhcTc (LHsCmd GhcTc)], a)
addTickLCmdStmts' lstmts res
  = bindLocals lstmts $ do
        lstmts' <- mapM (traverse addTickCmdStmt) lstmts
        a <- res
        return (lstmts', a)

addTickCmdStmt :: Stmt GhcTc (LHsCmd GhcTc) -> TM (Stmt GhcTc (LHsCmd GhcTc))
addTickCmdStmt (BindStmt x pat c) =
      bindLocals pat $
        liftM2 (BindStmt x)
                (addTickLPat pat)
                (addTickLHsCmd c)
addTickCmdStmt (LastStmt x c noret ret) =
        liftM3 (LastStmt x)
                (addTickLHsCmd c)
                (pure noret)
                (addTickSyntaxExpr hpcSrcSpan ret)
addTickCmdStmt (BodyStmt x c bind' guard') =
        liftM3 (BodyStmt x)
                (addTickLHsCmd c)
                (addTickSyntaxExpr hpcSrcSpan bind')
                (addTickSyntaxExpr hpcSrcSpan guard')
addTickCmdStmt (LetStmt x binds) =
        liftM (LetStmt x)
                (addTickHsLocalBinds binds)
addTickCmdStmt stmt@(RecStmt {})
  = do { stmts' <- addTickLCmdStmts (unLoc $ recS_stmts stmt)
       ; ret'   <- addTickSyntaxExpr hpcSrcSpan (recS_ret_fn stmt)
       ; mfix'  <- addTickSyntaxExpr hpcSrcSpan (recS_mfix_fn stmt)
       ; bind'  <- addTickSyntaxExpr hpcSrcSpan (recS_bind_fn stmt)
       ; return (stmt { recS_stmts = noLocA stmts', recS_ret_fn = ret'
                      , recS_mfix_fn = mfix', recS_bind_fn = bind' }) }
addTickCmdStmt (XStmtLR (ApplicativeStmt{})) =
  panic "ToDo: addTickCmdStmt ApplicativeLastStmt"

-- Others should never happen in a command context.
addTickCmdStmt stmt  = pprPanic "addTickHsCmd" (ppr stmt)

addTickHsRecordBinds :: HsRecordBinds GhcTc -> TM (HsRecordBinds GhcTc)
addTickHsRecordBinds (HsRecFields x fields dd)
  = do  { fields' <- mapM addTickHsRecField fields
        ; return (HsRecFields x fields' dd) }

addTickHsRecField :: LHsFieldBind GhcTc id (LHsExpr GhcTc)
                  -> TM (LHsFieldBind GhcTc id (LHsExpr GhcTc))
addTickHsRecField (L l (HsFieldBind x id expr pun))
        = do { expr' <- addTickLHsExpr expr
             ; return (L l (HsFieldBind x id expr' pun)) }

addTickArithSeqInfo :: ArithSeqInfo GhcTc -> TM (ArithSeqInfo GhcTc)
addTickArithSeqInfo (From e1) =
        liftM From
                (addTickLHsExpr e1)
addTickArithSeqInfo (FromThen e1 e2) =
        liftM2 FromThen
                (addTickLHsExpr e1)
                (addTickLHsExpr e2)
addTickArithSeqInfo (FromTo e1 e2) =
        liftM2 FromTo
                (addTickLHsExpr e1)
                (addTickLHsExpr e2)
addTickArithSeqInfo (FromThenTo e1 e2 e3) =
        liftM3 FromThenTo
                (addTickLHsExpr e1)
                (addTickLHsExpr e2)
                (addTickLHsExpr e3)

data TickTransState = TT { ticks       :: !(SizedSeq Tick)
                         , ccIndices   :: !CostCentreState
                         , recSelTicks :: !(IdEnv CoreTickish)
                         }

initTTState :: TickTransState
initTTState = TT { ticks        = emptySS
                 , ccIndices    = newCostCentreState
                 , recSelTicks  = emptyVarEnv
                 }

addMixEntry :: Tick -> TM Int
addMixEntry ent = do
  c <- fromIntegral . sizeSS . ticks <$> getState
  setState $ \st ->
    st { ticks = addToSS (ticks st) ent
       }
  return c

addRecSelTick :: Id -> CoreTickish -> TM ()
addRecSelTick sel tick =
  setState $ \s -> s{ recSelTicks = extendVarEnv (recSelTicks s) sel tick }

data TickTransEnv = TTE { fileName     :: FastString
                        , density      :: TickDensity
                        , tte_countEntries :: !Bool
                          -- ^ Whether the number of times functions are
                          -- entered should be counted.
                        , exports      :: NameSet
                        , inlines      :: VarSet
                        , declPath     :: [String]
                        , inScope      :: VarSet
                        , blackList    :: Set RealSrcSpan
                        , this_mod     :: Module
                        , tickishType  :: TickishType
                        , recSelBinds  :: IdEnv Id
                        }

--      deriving Show

-- | Reasons why we need ticks,
data TickishType
  -- | For profiling
  = ProfNotes
  -- | For Haskell Program Coverage
  | HpcTicks
  -- | For ByteCode interpreter break points
  | Breakpoints
  -- | For source notes
  | SourceNotes
  deriving (Eq)

-- | Tickishs that only make sense when their source code location
-- refers to the current file. This might not always be true due to
-- LINE pragmas in the code - which would confuse at least HPC.
tickSameFileOnly :: TickishType -> Bool
tickSameFileOnly HpcTicks = True
tickSameFileOnly _other   = False

type FreeVars = OccEnv Id
noFVs :: FreeVars
noFVs = emptyOccEnv

-- Note [freevars]
-- ~~~~~~~~~~~~~~~
--   For breakpoints we want to collect the free variables of an
--   expression for pinning on the HsTick.  We don't want to collect
--   *all* free variables though: in particular there's no point pinning
--   on free variables that are will otherwise be in scope at the GHCi
--   prompt, which means all top-level bindings.  Unfortunately detecting
--   top-level bindings isn't easy (collectHsBindsBinders on the top-level
--   bindings doesn't do it), so we keep track of a set of "in-scope"
--   variables in addition to the free variables, and the former is used
--   to filter additions to the latter.  This gives us complete control
--   over what free variables we track.

newtype TM a = TM { unTM :: TickTransEnv -> TickTransState -> (a,FreeVars,TickTransState) }
    deriving (Functor)
        -- a combination of a state monad (TickTransState) and a writer
        -- monad (FreeVars).

instance Applicative TM where
    pure a = TM $ \ _env st -> (a,noFVs,st)
    (<*>) = ap

instance Monad TM where
  (TM m) >>= k = TM $ \ env st ->
                                case m env st of
                                  (r1,fv1,st1) ->
                                     case unTM (k r1) env st1 of
                                       (r2,fv2,st2) ->
                                          (r2, fv1 `plusOccEnv` fv2, st2)


-- | Get the next HPC cost centre index for a given centre name
getCCIndexM :: FastString -> TM CostCentreIndex
getCCIndexM n = TM $ \_ st -> let (idx, is') = getCCIndex n $
                                                 ccIndices st
                              in (idx, noFVs, st { ccIndices = is' })

getState :: TM TickTransState
getState = TM $ \ _ st -> (st, noFVs, st)

setState :: (TickTransState -> TickTransState) -> TM ()
setState f = TM $ \ _ st -> ((), noFVs, f st)

getEnv :: TM TickTransEnv
getEnv = TM $ \ env st -> (env, noFVs, st)

withEnv :: (TickTransEnv -> TickTransEnv) -> TM a -> TM a
withEnv f (TM m) = TM $ \ env st ->
                                 case m (f env) st of
                                   (a, fvs, st') -> (a, fvs, st')

getDensity :: TM TickDensity
getDensity = TM $ \env st -> (density env, noFVs, st)

ifDensity :: TickDensity -> TM a -> TM a -> TM a
ifDensity d th el = do d0 <- getDensity; if d == d0 then th else el

getFreeVars :: TM a -> TM (FreeVars, a)
getFreeVars (TM m)
  = TM $ \ env st -> case m env st of (a, fv, st') -> ((fv,a), fv, st')

freeVar :: Id -> TM ()
freeVar id = TM $ \ env st ->
                if id `elemVarSet` inScope env
                   then ((), unitOccEnv (nameOccName (idName id)) id, st)
                   else ((), noFVs, st)

addPathEntry :: String -> TM a -> TM a
addPathEntry nm = withEnv (\ env -> env { declPath = declPath env ++ [nm] })

getPathEntry :: TM [String]
getPathEntry = declPath `liftM` getEnv

getFileName :: TM FastString
getFileName = fileName `liftM` getEnv

isGoodSrcSpan' :: SrcSpan -> Bool
isGoodSrcSpan' pos@(RealSrcSpan _ _) = srcSpanStart pos /= srcSpanEnd pos
isGoodSrcSpan' (UnhelpfulSpan _) = False

isGoodTickSrcSpan :: SrcSpan -> TM Bool
isGoodTickSrcSpan pos = do
  file_name <- getFileName
  tickish <- tickishType `liftM` getEnv
  let need_same_file = tickSameFileOnly tickish
      same_file      = Just file_name == srcSpanFileName_maybe pos
  isBL <- isBlackListed pos
  return (isGoodSrcSpan' pos && not isBL && (not need_same_file || same_file))

ifGoodTickSrcSpan :: SrcSpan -> TM a -> TM a -> TM a
ifGoodTickSrcSpan pos then_code else_code = do
  good <- isGoodTickSrcSpan pos
  if good then then_code else else_code

bindLocals :: (CollectBinders bndr, CollectFldBinders bndr) => bndr -> TM a -> TM a
bindLocals from (TM m) = TM $ \env st ->
  case m (with_bnds env) st of
    (r, fv, st') -> (r, fv `delListFromOccEnv` (map (nameOccName . idName) new_bnds), st')
  where with_bnds e = e{ inScope = inScope e `extendVarSetList` new_bnds
                       , recSelBinds = recSelBinds e `plusVarEnv` collectFldBinds from }
        new_bnds = collectBinds from

withBlackListed :: SrcSpan -> TM a -> TM a
withBlackListed (RealSrcSpan ss _) = withEnv (\ env -> env { blackList = Set.insert ss (blackList env) })
withBlackListed (UnhelpfulSpan _)  = id

isBlackListed :: SrcSpan -> TM Bool
isBlackListed (RealSrcSpan pos _) = TM $ \ env st -> (Set.member pos (blackList env), noFVs, st)
isBlackListed (UnhelpfulSpan _) = return False

-- the tick application inherits the source position of its
-- expression argument to support nested box allocations
allocTickBox :: BoxLabel -> Bool -> Bool -> SrcSpan -> TM (HsExpr GhcTc)
             -> TM (LHsExpr GhcTc)
allocTickBox boxLabel countEntries topOnly pos m
  = ifGoodTickSrcSpan pos good_case skip_case
  where
    this_loc = L (noAnnSrcSpan pos)
    skip_case = do
      e <- m
      return (this_loc e)
    good_case = do
      (fvs, e) <- getFreeVars m
      env <- getEnv
      tickish <- mkTickish boxLabel countEntries topOnly pos fvs (declPath env)
      return (this_loc (XExpr $ HsTick tickish $ this_loc e))

recSelTick :: Id -> TM (Maybe CoreTickish)
recSelTick id = ifDensity TickForCoverage maybe_tick (pure Nothing)
  where
    maybe_tick = getEnv >>=
      maybe (pure Nothing) tick . (`lookupVarEnv` id) . recSelBinds
    tick sel = getState >>=
      maybe (alloc sel) (pure . Just) . (`lookupVarEnv` sel) . recSelTicks
    alloc sel = allocATickBox (box sel) False False (getSrcSpan sel) noFVs
                  >>= traverse (\t -> t <$ addRecSelTick sel t)
    box sel = TopLevelBox [getOccString sel]

-- the tick application inherits the source position of its
-- expression argument to support nested box allocations
allocATickBox :: BoxLabel -> Bool -> Bool -> SrcSpan -> FreeVars
              -> TM (Maybe CoreTickish)
allocATickBox boxLabel countEntries topOnly  pos fvs =
  ifGoodTickSrcSpan pos (do
    let
      mydecl_path = case boxLabel of
                      TopLevelBox x -> x
                      LocalBox xs  -> xs
                      _ -> panic "allocATickBox"
    tickish <- mkTickish boxLabel countEntries topOnly pos fvs mydecl_path
    return (Just tickish)
  ) (return Nothing)


mkTickish :: BoxLabel -> Bool -> Bool -> SrcSpan -> OccEnv Id -> [String]
          -> TM CoreTickish
mkTickish boxLabel countEntries topOnly pos fvs decl_path = do

  let ids = filter (not . mightBeUnliftedType . idType) $ nonDetOccEnvElts fvs
          -- unlifted types cause two problems here:
          --   * we can't bind them  at the GHCi prompt
          --     (bindLocalsAtBreakpoint already filters them out),
          --   * the simplifier might try to substitute a literal for
          --     the Id, and we can't handle that.

      me = Tick
        { tick_loc   = pos
        , tick_path  = decl_path
        , tick_ids   = map (nameOccName.idName) ids
        , tick_label = boxLabel
        }

      cc_name | topOnly   = mkFastString $ head decl_path
              | otherwise = mkFastString $ concat (intersperse "." decl_path)

  env <- getEnv
  case tickishType env of
    HpcTicks -> HpcTick (this_mod env) <$> addMixEntry me

    ProfNotes -> do
      flavour <- mkHpcCCFlavour <$> getCCIndexM cc_name
      let cc = mkUserCC cc_name (this_mod env) pos flavour
          count = countEntries && tte_countEntries env
      return $ ProfNote cc count True{-scopes-}

    Breakpoints -> do
      i <- addMixEntry me
      pure (Breakpoint noExtField (BreakpointId (this_mod env) i) ids)

    SourceNotes | RealSrcSpan pos' _ <- pos ->
      return $ SourceNote pos' $ LexicalFastString cc_name

    _otherwise -> panic "mkTickish: bad source span!"


allocBinTickBox :: (Bool -> BoxLabel) -> SrcSpan -> TM (HsExpr GhcTc)
                -> TM (LHsExpr GhcTc)
allocBinTickBox boxLabel pos m = do
  env <- getEnv
  case tickishType env of
    HpcTicks -> do e <- liftM (L (noAnnSrcSpan pos)) m
                   ifGoodTickSrcSpan pos
                     (mkBinTickBoxHpc boxLabel pos e)
                     (return e)
    _other   -> allocTickBox (ExpBox False) False False pos m

mkBinTickBoxHpc :: (Bool -> BoxLabel) -> SrcSpan -> LHsExpr GhcTc
                -> TM (LHsExpr GhcTc)
mkBinTickBoxHpc boxLabel pos e = do
  env <- getEnv
  binTick <- HsBinTick
    <$> addMixEntry (Tick { tick_loc = pos
                          , tick_path = declPath env
                          , tick_ids = []
                          , tick_label = boxLabel True
                          })
    <*> addMixEntry (Tick { tick_loc = pos
                          , tick_path = declPath env
                          , tick_ids = []
                          , tick_label = boxLabel False
                          })
    <*> pure e
  tick <- HpcTick (this_mod env)
    <$> addMixEntry (Tick { tick_loc = pos
                          , tick_path = declPath env
                          , tick_ids = []
                          , tick_label = ExpBox False
                          })
  let pos' = noAnnSrcSpan pos
  return $ L pos' $ XExpr $ HsTick tick (L pos' (XExpr binTick))

hpcSrcSpan :: SrcSpan
hpcSrcSpan = mkGeneralSrcSpan (fsLit "Haskell Program Coverage internals")

matchesOneOfMany :: [LMatch GhcTc body] -> Bool
matchesOneOfMany lmatches = sum (map matchCount lmatches) > 1
  where
        matchCount :: LMatch GhcTc body -> Int
        matchCount (L _ (Match { m_grhss = GRHSs _ grhss _ }))
          = length grhss

-- | Convenience class used by 'bindLocals' to collect new bindings from
-- various parts of he AST. Just delegates to
-- 'collect{Pat,Pats,Local,LStmts}Binders' from 'GHC.Hs.Utils' as appropriate.
class CollectBinders a where
  collectBinds :: a -> [Id]

-- | Variant of 'CollectBinders' which collects information on which locals
-- are bound to record fields (currently only via 'RecordWildCards' or
-- 'NamedFieldPuns') to enable better coverage support for record selectors.
--
-- See Note [Record-selector ticks].
class CollectFldBinders a where
  collectFldBinds :: a -> IdEnv Id

instance CollectBinders (LocatedA (Pat GhcTc)) where
  collectBinds = collectPatBinders CollNoDictBinders
instance CollectBinders [LocatedA (Pat GhcTc)] where
  collectBinds = collectPatsBinders CollNoDictBinders
instance CollectBinders (HsLocalBinds GhcTc) where
  collectBinds = collectLocalBinders CollNoDictBinders
instance CollectBinders [LocatedA (Stmt GhcTc (LocatedA (HsExpr GhcTc)))] where
  collectBinds = collectLStmtsBinders CollNoDictBinders
instance CollectBinders [LocatedA (Stmt GhcTc (LocatedA (HsCmd GhcTc)))] where
  collectBinds = collectLStmtsBinders CollNoDictBinders

instance (CollectFldBinders a) => CollectFldBinders [a] where
  collectFldBinds = foldr (flip plusVarEnv . collectFldBinds) emptyVarEnv
instance (CollectFldBinders e) => CollectFldBinders (GenLocated l e) where
  collectFldBinds = collectFldBinds . unLoc
instance CollectFldBinders (Pat GhcTc) where
  collectFldBinds ConPat{ pat_args = RecCon HsRecFields{ rec_flds, rec_dotdot } } =
    collectFldBinds rec_flds `plusVarEnv` plusVarEnvList (zipWith fld_bnds [0..] rec_flds)
    where n_explicit | Just (L _ (RecFieldsDotDot n)) <- rec_dotdot = n
                     | otherwise = length rec_flds
          fld_bnds n (L _ HsFieldBind{ hfbLHS = L _ FieldOcc{ foLabel = L _ sel }
                                     , hfbRHS = L _ (VarPat _ (L _ var))
                                     , hfbPun })
            | hfbPun || n >= n_explicit = unitVarEnv var sel
          fld_bnds _ _ = emptyVarEnv
  collectFldBinds ConPat{ pat_args = PrefixCon pats } = collectFldBinds pats
  collectFldBinds ConPat{ pat_args = InfixCon p1 p2 } = collectFldBinds [p1, p2]
  collectFldBinds (LazyPat _ pat) = collectFldBinds pat
  collectFldBinds (BangPat _ pat) = collectFldBinds pat
  collectFldBinds (AsPat _ _ pat) = collectFldBinds pat
  collectFldBinds (ViewPat _ _ pat) = collectFldBinds pat
  collectFldBinds (ParPat _ pat) = collectFldBinds pat
  collectFldBinds (ListPat _ pats) = collectFldBinds pats
  collectFldBinds (TuplePat _ pats _) = collectFldBinds pats
  collectFldBinds (SumPat _ pats _ _) = collectFldBinds pats
  collectFldBinds (SigPat _ pat _) = collectFldBinds pat
  collectFldBinds (XPat exp) = collectFldBinds exp
  collectFldBinds VarPat{} = emptyVarEnv
  collectFldBinds WildPat{} = emptyVarEnv
  collectFldBinds OrPat{} = emptyVarEnv
  collectFldBinds LitPat{} = emptyVarEnv
  collectFldBinds NPat{} = emptyVarEnv
  collectFldBinds NPlusKPat{} = emptyVarEnv
  collectFldBinds SplicePat{} = emptyVarEnv
  collectFldBinds EmbTyPat{} = emptyVarEnv
  collectFldBinds InvisPat{} = emptyVarEnv
instance (CollectFldBinders r) => CollectFldBinders (HsFieldBind l r) where
  collectFldBinds = collectFldBinds . hfbRHS
instance CollectFldBinders XXPatGhcTc where
  collectFldBinds (CoPat _ pat _) = collectFldBinds pat
  collectFldBinds (ExpansionPat _ pat) = collectFldBinds pat
instance CollectFldBinders (HsLocalBinds GhcTc) where
  collectFldBinds (HsValBinds _ bnds) = collectFldBinds bnds
  collectFldBinds HsIPBinds{} = emptyVarEnv
  collectFldBinds EmptyLocalBinds{} = emptyVarEnv
instance CollectFldBinders (HsValBinds GhcTc) where
  collectFldBinds (ValBinds _ bnds _) = collectFldBinds bnds
  collectFldBinds (XValBindsLR (NValBinds bnds _)) = collectFldBinds (map snd bnds)
instance CollectFldBinders (HsBind GhcTc) where
  collectFldBinds PatBind{ pat_lhs } = collectFldBinds pat_lhs
  collectFldBinds (XHsBindsLR AbsBinds{ abs_exports, abs_binds }) =
    mkVarEnv [ (abe_poly, sel)
             | ABE{ abe_poly, abe_mono } <- abs_exports
             , Just sel <- [lookupVarEnv monos abe_mono] ]
    where monos = collectFldBinds abs_binds
  collectFldBinds VarBind{} = emptyVarEnv
  collectFldBinds FunBind{} = emptyVarEnv
  collectFldBinds PatSynBind{} = emptyVarEnv
instance CollectFldBinders (Stmt GhcTc e) where
  collectFldBinds (BindStmt _ pat _) = collectFldBinds pat
  collectFldBinds (LetStmt _ bnds) = collectFldBinds bnds
  collectFldBinds (ParStmt _ xs _ _) = collectFldBinds [s | ParStmtBlock _ ss _ _ <- toList xs, s <- ss]
  collectFldBinds TransStmt{ trS_stmts } = collectFldBinds trS_stmts
  collectFldBinds RecStmt{ recS_stmts } = collectFldBinds recS_stmts
  collectFldBinds (XStmtLR (ApplicativeStmt _ args _)) = collectFldBinds (map snd args)
  collectFldBinds LastStmt{} = emptyVarEnv
  collectFldBinds BodyStmt{} = emptyVarEnv
instance CollectFldBinders (ApplicativeArg GhcTc) where
  collectFldBinds ApplicativeArgOne{ app_arg_pattern } = collectFldBinds app_arg_pattern
  collectFldBinds ApplicativeArgMany{ bv_pattern } = collectFldBinds bv_pattern
