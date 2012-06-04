%
% (c) The University of Glasgow 2006
%

Functions for working with the typechecker environment (setters, getters...).

\begin{code}
module TcRnMonad(
        module TcRnMonad,
        module TcRnTypes,
        module IOEnv
  ) where

#include "HsVersions.h"

import TcRnTypes        -- Re-export all
import IOEnv            -- Re-export all
import TcEvidence

import HsSyn hiding (LIE)
import HscTypes
import Module
import RdrName
import Name
import Type
import TcType
import InstEnv
import FamInstEnv
import PrelNames

import Var
import Id
import VarSet
import VarEnv
import ErrUtils
import SrcLoc
import NameEnv
import NameSet
import Bag
import Outputable
import UniqSupply
import Unique
import UniqFM
import DynFlags
import StaticFlags
import FastString
import Panic
import Util

import System.IO
import Data.IORef
import qualified Data.Set as Set
import Control.Monad
\end{code}



%************************************************************************
%*                                                                      *
                        initTc
%*                                                                      *
%************************************************************************

\begin{code}

-- | Setup the initial typechecking environment
initTc :: HscEnv
       -> HscSource
       -> Bool          -- True <=> retain renamed syntax trees
       -> Module
       -> TcM r
       -> IO (Messages, Maybe r)
                -- Nothing => error thrown by the thing inside
                -- (error messages should have been printed already)

initTc hsc_env hsc_src keep_rn_syntax mod do_this
 = do { errs_var     <- newIORef (emptyBag, emptyBag) ;
        meta_var     <- newIORef initTyVarUnique ;
        tvs_var      <- newIORef emptyVarSet ;
        keep_var     <- newIORef emptyNameSet ;
        used_rdr_var <- newIORef Set.empty ;
        th_var       <- newIORef False ;
        th_splice_var<- newIORef False ;
        infer_var    <- newIORef True ;
        lie_var      <- newIORef emptyWC ;
        dfun_n_var   <- newIORef emptyOccSet ;
        type_env_var <- case hsc_type_env_var hsc_env of {
                           Just (_mod, te_var) -> return te_var ;
                           Nothing             -> newIORef emptyNameEnv } ;

        dependent_files_var <- newIORef [] ;
        let {
             maybe_rn_syntax :: forall a. a -> Maybe a ;
             maybe_rn_syntax empty_val
                | keep_rn_syntax = Just empty_val
                | otherwise      = Nothing ;

             gbl_env = TcGblEnv {
                tcg_mod            = mod,
                tcg_src            = hsc_src,
                tcg_rdr_env        = emptyGlobalRdrEnv,
                tcg_fix_env        = emptyNameEnv,
                tcg_field_env      = RecFields emptyNameEnv emptyNameSet,
                tcg_default        = Nothing,
                tcg_type_env       = emptyNameEnv,
                tcg_type_env_var   = type_env_var,
                tcg_inst_env       = emptyInstEnv,
                tcg_fam_inst_env   = emptyFamInstEnv,
                tcg_th_used        = th_var,
                tcg_th_splice_used = th_splice_var,
                tcg_exports        = [],
                tcg_imports        = emptyImportAvails,
                tcg_used_rdrnames  = used_rdr_var,
                tcg_dus            = emptyDUs,

                tcg_rn_imports     = [],
                tcg_rn_exports     = maybe_rn_syntax [],
                tcg_rn_decls       = maybe_rn_syntax emptyRnGroup,

                tcg_binds          = emptyLHsBinds,
                tcg_imp_specs      = [],
                tcg_sigs           = emptyNameSet,
                tcg_ev_binds       = emptyBag,
                tcg_warns          = NoWarnings,
                tcg_anns           = [],
                tcg_tcs            = [],
                tcg_insts          = [],
                tcg_fam_insts      = [],
                tcg_rules          = [],
                tcg_fords          = [],
                tcg_vects          = [],
                tcg_dfun_n         = dfun_n_var,
                tcg_keep           = keep_var,
                tcg_doc_hdr        = Nothing,
                tcg_hpc            = False,
                tcg_main           = Nothing,
                tcg_safeInfer      = infer_var,
                tcg_dependent_files = dependent_files_var
             } ;
             lcl_env = TcLclEnv {
                tcl_errs       = errs_var,
                tcl_loc        = mkGeneralSrcSpan (fsLit "Top level"),
                tcl_ctxt       = [],
                tcl_rdr        = emptyLocalRdrEnv,
                tcl_th_ctxt    = topStage,
                tcl_arrow_ctxt = NoArrowCtxt,
                tcl_env        = emptyNameEnv,
                tcl_tyvars     = tvs_var,
                tcl_lie        = lie_var,
                tcl_meta       = meta_var,
                tcl_untch      = initTyVarUnique
             } ;
        } ;

        -- OK, here's the business end!
        maybe_res <- initTcRnIf 'a' hsc_env gbl_env lcl_env $
                     do { r <- tryM do_this
                        ; case r of
                          Right res -> return (Just res)
                          Left _    -> return Nothing } ;

        -- Check for unsolved constraints
        lie <- readIORef lie_var ;
        if isEmptyWC lie
           then return ()
           else pprPanic "initTc: unsolved constraints"
                         (pprWantedsWithLocs lie) ;

        -- Collect any error messages
        msgs <- readIORef errs_var ;

        let { dflags = hsc_dflags hsc_env
            ; final_res | errorsFound dflags msgs = Nothing
                        | otherwise               = maybe_res } ;

        return (msgs, final_res)
    }

initTcPrintErrors       -- Used from the interactive loop only
       :: HscEnv
       -> Module
       -> TcM r
       -> IO (Messages, Maybe r)

initTcPrintErrors env mod todo = initTc env HsSrcFile False mod todo
\end{code}

%************************************************************************
%*                                                                      *
                Initialisation
%*                                                                      *
%************************************************************************


\begin{code}
initTcRnIf :: Char              -- Tag for unique supply
           -> HscEnv
           -> gbl -> lcl
           -> TcRnIf gbl lcl a
           -> IO a
initTcRnIf uniq_tag hsc_env gbl_env lcl_env thing_inside
   = do { us     <- mkSplitUniqSupply uniq_tag ;
        ; us_var <- newIORef us ;

        ; let { env = Env { env_top = hsc_env,
                            env_us  = us_var,
                            env_gbl = gbl_env,
                            env_lcl = lcl_env} }

        ; runIOEnv env thing_inside
        }
\end{code}

%************************************************************************
%*                                                                      *
                Simple accessors
%*                                                                      *
%************************************************************************

\begin{code}
getTopEnv :: TcRnIf gbl lcl HscEnv
getTopEnv = do { env <- getEnv; return (env_top env) }

getGblEnv :: TcRnIf gbl lcl gbl
getGblEnv = do { env <- getEnv; return (env_gbl env) }

updGblEnv :: (gbl -> gbl) -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
updGblEnv upd = updEnv (\ env@(Env { env_gbl = gbl }) ->
                          env { env_gbl = upd gbl })

setGblEnv :: gbl -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
setGblEnv gbl_env = updEnv (\ env -> env { env_gbl = gbl_env })

getLclEnv :: TcRnIf gbl lcl lcl
getLclEnv = do { env <- getEnv; return (env_lcl env) }

updLclEnv :: (lcl -> lcl) -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
updLclEnv upd = updEnv (\ env@(Env { env_lcl = lcl }) ->
                          env { env_lcl = upd lcl })

setLclEnv :: lcl' -> TcRnIf gbl lcl' a -> TcRnIf gbl lcl a
setLclEnv lcl_env = updEnv (\ env -> env { env_lcl = lcl_env })

getEnvs :: TcRnIf gbl lcl (gbl, lcl)
getEnvs = do { env <- getEnv; return (env_gbl env, env_lcl env) }

setEnvs :: (gbl', lcl') -> TcRnIf gbl' lcl' a -> TcRnIf gbl lcl a
setEnvs (gbl_env, lcl_env) = updEnv (\ env -> env { env_gbl = gbl_env, env_lcl = lcl_env })
\end{code}


Command-line flags

\begin{code}
getDOpts :: TcRnIf gbl lcl DynFlags
getDOpts = do { env <- getTopEnv; return (hsc_dflags env) }

xoptM :: ExtensionFlag -> TcRnIf gbl lcl Bool
xoptM flag = do { dflags <- getDOpts; return (xopt flag dflags) }

doptM :: DynFlag -> TcRnIf gbl lcl Bool
doptM flag = do { dflags <- getDOpts; return (dopt flag dflags) }

woptM :: WarningFlag -> TcRnIf gbl lcl Bool
woptM flag = do { dflags <- getDOpts; return (wopt flag dflags) }

setXOptM :: ExtensionFlag -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
setXOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                          env { env_top = top { hsc_dflags = xopt_set (hsc_dflags top) flag}} )

unsetDOptM :: DynFlag -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
unsetDOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                            env { env_top = top { hsc_dflags = dopt_unset (hsc_dflags top) flag}} )

unsetWOptM :: WarningFlag -> TcRnIf gbl lcl a -> TcRnIf gbl lcl a
unsetWOptM flag = updEnv (\ env@(Env { env_top = top }) ->
                            env { env_top = top { hsc_dflags = wopt_unset (hsc_dflags top) flag}} )

-- | Do it flag is true
ifDOptM :: DynFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
ifDOptM flag thing_inside = do { b <- doptM flag ;
                                if b then thing_inside else return () }

ifWOptM :: WarningFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
ifWOptM flag thing_inside = do { b <- woptM flag ;
                                if b then thing_inside else return () }

ifXOptM :: ExtensionFlag -> TcRnIf gbl lcl () -> TcRnIf gbl lcl ()
ifXOptM flag thing_inside = do { b <- xoptM flag ;
                                if b then thing_inside else return () }

getGhcMode :: TcRnIf gbl lcl GhcMode
getGhcMode = do { env <- getTopEnv; return (ghcMode (hsc_dflags env)) }
\end{code}

\begin{code}
getEpsVar :: TcRnIf gbl lcl (TcRef ExternalPackageState)
getEpsVar = do { env <- getTopEnv; return (hsc_EPS env) }

getEps :: TcRnIf gbl lcl ExternalPackageState
getEps = do { env <- getTopEnv; readMutVar (hsc_EPS env) }

-- | Update the external package state.  Returns the second result of the
-- modifier function.
--
-- This is an atomic operation and forces evaluation of the modified EPS in
-- order to avoid space leaks.
updateEps :: (ExternalPackageState -> (ExternalPackageState, a))
          -> TcRnIf gbl lcl a
updateEps upd_fn = do
  traceIf (text "updating EPS")
  eps_var <- getEpsVar
  atomicUpdMutVar' eps_var upd_fn

-- | Update the external package state.
--
-- This is an atomic operation and forces evaluation of the modified EPS in
-- order to avoid space leaks.
updateEps_ :: (ExternalPackageState -> ExternalPackageState)
           -> TcRnIf gbl lcl ()
updateEps_ upd_fn = do
  traceIf (text "updating EPS_")
  eps_var <- getEpsVar
  atomicUpdMutVar' eps_var (\eps -> (upd_fn eps, ()))

getHpt :: TcRnIf gbl lcl HomePackageTable
getHpt = do { env <- getTopEnv; return (hsc_HPT env) }

getEpsAndHpt :: TcRnIf gbl lcl (ExternalPackageState, HomePackageTable)
getEpsAndHpt = do { env <- getTopEnv; eps <- readMutVar (hsc_EPS env)
                  ; return (eps, hsc_HPT env) }
\end{code}

%************************************************************************
%*                                                                      *
                Unique supply
%*                                                                      *
%************************************************************************

\begin{code}
newMetaUnique :: TcM Unique
-- The uniques for TcMetaTyVars are allocated specially
-- in guaranteed linear order, starting at zero for each module
newMetaUnique
 = do { env <- getLclEnv
      ; let meta_var = tcl_meta env
      ; uniq <- readMutVar meta_var
      ; writeMutVar meta_var (incrUnique uniq)
      ; return uniq }

newUnique :: TcRnIf gbl lcl Unique
newUnique
 = do { env <- getEnv ;
        let { u_var = env_us env } ;
        us <- readMutVar u_var ;
        case takeUniqFromSupply us of { (uniq, us') -> do {
        writeMutVar u_var us' ;
        return $! uniq }}}
   -- NOTE 1: we strictly split the supply, to avoid the possibility of leaving
   -- a chain of unevaluated supplies behind.
   -- NOTE 2: we use the uniq in the supply from the MutVar directly, and
   -- throw away one half of the new split supply.  This is safe because this
   -- is the only place we use that unique.  Using the other half of the split
   -- supply is safer, but slower.

newUniqueSupply :: TcRnIf gbl lcl UniqSupply
newUniqueSupply
 = do { env <- getEnv ;
        let { u_var = env_us env } ;
        us <- readMutVar u_var ;
        case splitUniqSupply us of { (us1,us2) -> do {
        writeMutVar u_var us1 ;
        return us2 }}}

newLocalName :: Name -> TcRnIf gbl lcl Name
newLocalName name       -- Make a clone
  = do  { uniq <- newUnique
        ; return (mkInternalName uniq (nameOccName name) (getSrcSpan name)) }

newSysLocalIds :: FastString -> [TcType] -> TcRnIf gbl lcl [TcId]
newSysLocalIds fs tys
  = do  { us <- newUniqueSupply
        ; return (zipWith (mkSysLocal fs) (uniqsFromSupply us) tys) }

newName :: OccName -> TcM Name
newName occ
  = do { uniq <- newUnique
       ; loc  <- getSrcSpanM
       ; return (mkInternalName uniq occ loc) }

instance MonadUnique (IOEnv (Env gbl lcl)) where
        getUniqueM = newUnique
        getUniqueSupplyM = newUniqueSupply
\end{code}


%************************************************************************
%*                                                                      *
                Debugging
%*                                                                      *
%************************************************************************

\begin{code}
newTcRef :: a -> TcRnIf gbl lcl (TcRef a)
newTcRef = newMutVar

readTcRef :: TcRef a -> TcRnIf gbl lcl a
readTcRef = readMutVar

writeTcRef :: TcRef a -> a -> TcRnIf gbl lcl ()
writeTcRef = writeMutVar

updTcRef :: TcRef a -> (a -> a) -> TcRnIf gbl lcl ()
updTcRef = updMutVar
\end{code}

%************************************************************************
%*                                                                      *
                Debugging
%*                                                                      *
%************************************************************************

\begin{code}
traceTc :: String -> SDoc -> TcRn ()
traceTc = traceTcN 1

traceTcN :: Int -> String -> SDoc -> TcRn ()
traceTcN level herald doc
  | level <= opt_TraceLevel = traceOptTcRn Opt_D_dump_tc_trace $
                              hang (text herald) 2 doc
  | otherwise               = return ()

traceRn, traceSplice :: SDoc -> TcRn ()
traceRn      = traceOptTcRn Opt_D_dump_rn_trace
traceSplice  = traceOptTcRn Opt_D_dump_splices

traceIf, traceHiDiffs :: SDoc -> TcRnIf m n ()
traceIf      = traceOptIf Opt_D_dump_if_trace
traceHiDiffs = traceOptIf Opt_D_dump_hi_diffs


traceOptIf :: DynFlag -> SDoc -> TcRnIf m n ()  -- No RdrEnv available, so qualify everything
traceOptIf flag doc = ifDOptM flag $
                      liftIO (printForUser stderr alwaysQualify doc)

traceOptTcRn :: DynFlag -> SDoc -> TcRn ()
-- Output the message, with current location if opt_PprStyle_Debug
traceOptTcRn flag doc = ifDOptM flag $ do
                        { loc  <- getSrcSpanM
                        ; let real_doc
                                | opt_PprStyle_Debug = mkLocMessage loc doc
                                | otherwise = doc   -- The full location is
                                                    -- usually way too much
                        ; dumpTcRn real_doc }

dumpTcRn :: SDoc -> TcRn ()
dumpTcRn doc = do { rdr_env <- getGlobalRdrEnv
                  ; dflags <- getDOpts
                  ; liftIO (printForUser stderr (mkPrintUnqualified dflags rdr_env) doc) }

debugDumpTcRn :: SDoc -> TcRn ()
debugDumpTcRn doc | opt_NoDebugOutput = return ()
                  | otherwise         = dumpTcRn doc

dumpOptTcRn :: DynFlag -> SDoc -> TcRn ()
dumpOptTcRn flag doc = ifDOptM flag (dumpTcRn doc)
\end{code}


%************************************************************************
%*                                                                      *
                Typechecker global environment
%*                                                                      *
%************************************************************************

\begin{code}
getModule :: TcRn Module
getModule = do { env <- getGblEnv; return (tcg_mod env) }

setModule :: Module -> TcRn a -> TcRn a
setModule mod thing_inside = updGblEnv (\env -> env { tcg_mod = mod }) thing_inside

getIsGHCi :: TcRn Bool
getIsGHCi = do { mod <- getModule; return (mod == iNTERACTIVE) }

tcIsHsBoot :: TcRn Bool
tcIsHsBoot = do { env <- getGblEnv; return (isHsBoot (tcg_src env)) }

getGlobalRdrEnv :: TcRn GlobalRdrEnv
getGlobalRdrEnv = do { env <- getGblEnv; return (tcg_rdr_env env) }

getRdrEnvs :: TcRn (GlobalRdrEnv, LocalRdrEnv)
getRdrEnvs = do { (gbl,lcl) <- getEnvs; return (tcg_rdr_env gbl, tcl_rdr lcl) }

getImports :: TcRn ImportAvails
getImports = do { env <- getGblEnv; return (tcg_imports env) }

getFixityEnv :: TcRn FixityEnv
getFixityEnv = do { env <- getGblEnv; return (tcg_fix_env env) }

extendFixityEnv :: [(Name,FixItem)] -> RnM a -> RnM a
extendFixityEnv new_bit
  = updGblEnv (\env@(TcGblEnv { tcg_fix_env = old_fix_env }) ->
                env {tcg_fix_env = extendNameEnvList old_fix_env new_bit})

getRecFieldEnv :: TcRn RecFieldEnv
getRecFieldEnv = do { env <- getGblEnv; return (tcg_field_env env) }

getDeclaredDefaultTys :: TcRn (Maybe [Type])
getDeclaredDefaultTys = do { env <- getGblEnv; return (tcg_default env) }

addDependentFiles :: [FilePath] -> TcRn ()
addDependentFiles fs = do
  ref <- fmap tcg_dependent_files getGblEnv
  dep_files <- readTcRef ref
  writeTcRef ref (fs ++ dep_files)
\end{code}

%************************************************************************
%*                                                                      *
                Error management
%*                                                                      *
%************************************************************************

\begin{code}
getSrcSpanM :: TcRn SrcSpan
        -- Avoid clash with Name.getSrcLoc
getSrcSpanM = do { env <- getLclEnv; return (tcl_loc env) }

setSrcSpan :: SrcSpan -> TcRn a -> TcRn a
setSrcSpan loc@(RealSrcSpan _) thing_inside
    = updLclEnv (\env -> env { tcl_loc = loc }) thing_inside
-- Don't overwrite useful info with useless:
setSrcSpan (UnhelpfulSpan _) thing_inside = thing_inside

addLocM :: (a -> TcM b) -> Located a -> TcM b
addLocM fn (L loc a) = setSrcSpan loc $ fn a

wrapLocM :: (a -> TcM b) -> Located a -> TcM (Located b)
wrapLocM fn (L loc a) = setSrcSpan loc $ do b <- fn a; return (L loc b)

wrapLocFstM :: (a -> TcM (b,c)) -> Located a -> TcM (Located b, c)
wrapLocFstM fn (L loc a) =
  setSrcSpan loc $ do
    (b,c) <- fn a
    return (L loc b, c)

wrapLocSndM :: (a -> TcM (b,c)) -> Located a -> TcM (b, Located c)
wrapLocSndM fn (L loc a) =
  setSrcSpan loc $ do
    (b,c) <- fn a
    return (b, L loc c)
\end{code}

Reporting errors

\begin{code}
getErrsVar :: TcRn (TcRef Messages)
getErrsVar = do { env <- getLclEnv; return (tcl_errs env) }

setErrsVar :: TcRef Messages -> TcRn a -> TcRn a
setErrsVar v = updLclEnv (\ env -> env { tcl_errs =  v })

addErr :: Message -> TcRn ()    -- Ignores the context stack
addErr msg = do { loc <- getSrcSpanM; addErrAt loc msg }

failWith :: Message -> TcRn a
failWith msg = addErr msg >> failM

addErrAt :: SrcSpan -> Message -> TcRn ()
-- addErrAt is mainly (exclusively?) used by the renamer, where
-- tidying is not an issue, but it's all lazy so the extra
-- work doesn't matter
addErrAt loc msg = do { ctxt <- getErrCtxt
                      ; tidy_env <- tcInitTidyEnv
                      ; err_info <- mkErrInfo tidy_env ctxt
                      ; addLongErrAt loc msg err_info }

addErrs :: [(SrcSpan,Message)] -> TcRn ()
addErrs msgs = mapM_ add msgs
             where
               add (loc,msg) = addErrAt loc msg

addWarn :: Message -> TcRn ()
addWarn msg = addReport (ptext (sLit "Warning:") <+> msg) empty

addWarnAt :: SrcSpan -> Message -> TcRn ()
addWarnAt loc msg = addReportAt loc (ptext (sLit "Warning:") <+> msg) empty

checkErr :: Bool -> Message -> TcRn ()
-- Add the error if the bool is False
checkErr ok msg = unless ok (addErr msg)

warnIf :: Bool -> Message -> TcRn ()
warnIf True  msg = addWarn msg
warnIf False _   = return ()

addMessages :: Messages -> TcRn ()
addMessages (m_warns, m_errs)
  = do { errs_var <- getErrsVar ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns `unionBags` m_warns,
                               errs  `unionBags` m_errs) }

discardWarnings :: TcRn a -> TcRn a
-- Ignore warnings inside the thing inside;
-- used to ignore-unused-variable warnings inside derived code
discardWarnings thing_inside
  = do  { errs_var <- getErrsVar
        ; (old_warns, _) <- readTcRef errs_var ;

        ; result <- thing_inside

        -- Revert warnings to old_warns
        ; (_new_warns, new_errs) <- readTcRef errs_var
        ; writeTcRef errs_var (old_warns, new_errs) 

        ; return result }
\end{code}


%************************************************************************
%*                                                                      *
        Shared error message stuff: renamer and typechecker
%*                                                                      *
%************************************************************************

\begin{code}
addReport :: Message -> Message -> TcRn ()
addReport msg extra_info = do { traceTc "addr" msg; loc <- getSrcSpanM; addReportAt loc msg extra_info }

addReportAt :: SrcSpan -> Message -> Message -> TcRn ()
addReportAt loc msg extra_info
  = do { errs_var <- getErrsVar ;
         rdr_env <- getGlobalRdrEnv ;
         dflags <- getDOpts ;
         let { warn = mkLongWarnMsg loc (mkPrintUnqualified dflags rdr_env)
                                    msg extra_info } ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns `snocBag` warn, errs) }

addLongErrAt :: SrcSpan -> Message -> Message -> TcRn ()
addLongErrAt loc msg extra
  = do { traceTc "Adding error:" (mkLocMessage loc (msg $$ extra)) ;
         errs_var <- getErrsVar ;
         rdr_env <- getGlobalRdrEnv ;
         dflags <- getDOpts ;
         let { err = mkLongErrMsg loc (mkPrintUnqualified dflags rdr_env) msg extra } ;
         (warns, errs) <- readTcRef errs_var ;
         writeTcRef errs_var (warns, errs `snocBag` err) }

dumpDerivingInfo :: SDoc -> TcM ()
dumpDerivingInfo doc
  = do { dflags <- getDOpts
       ; when (dopt Opt_D_dump_deriv dflags) $ do
       { rdr_env <- getGlobalRdrEnv
       ; let unqual = mkPrintUnqualified dflags rdr_env
       ; liftIO (putMsgWith dflags unqual doc) } }
\end{code}


\begin{code}
try_m :: TcRn r -> TcRn (Either IOEnvFailure r)
-- Does try_m, with a debug-trace on failure
try_m thing
  = do { mb_r <- tryM thing ;
         case mb_r of
             Left exn -> do { traceTc "tryTc/recoverM recovering from" $
                                      text (showException exn)
                            ; return mb_r }
             Right _  -> return mb_r }

-----------------------
recoverM :: TcRn r      -- Recovery action; do this if the main one fails
         -> TcRn r      -- Main action: do this first
         -> TcRn r
-- Errors in 'thing' are retained
recoverM recover thing
  = do { mb_res <- try_m thing ;
         case mb_res of
           Left _    -> recover
           Right res -> return res }


-----------------------
mapAndRecoverM :: (a -> TcRn b) -> [a] -> TcRn [b]
-- Drop elements of the input that fail, so the result
-- list can be shorter than the argument list
mapAndRecoverM _ []     = return []
mapAndRecoverM f (x:xs) = do { mb_r <- try_m (f x)
                             ; rs <- mapAndRecoverM f xs
                             ; return (case mb_r of
                                          Left _  -> rs
                                          Right r -> r:rs) }


-----------------------
tryTc :: TcRn a -> TcRn (Messages, Maybe a)
-- (tryTc m) executes m, and returns
--      Just r,  if m succeeds (returning r)
--      Nothing, if m fails
-- It also returns all the errors and warnings accumulated by m
-- It always succeeds (never raises an exception)
tryTc m
 = do { errs_var <- newTcRef emptyMessages ;
        res  <- try_m (setErrsVar errs_var m) ;
        msgs <- readTcRef errs_var ;
        return (msgs, case res of
                            Left _  -> Nothing
                            Right val -> Just val)
        -- The exception is always the IOEnv built-in
        -- in exception; see IOEnv.failM
   }

-----------------------
tryTcErrs :: TcRn a -> TcRn (Messages, Maybe a)
-- Run the thing, returning
--      Just r,  if m succceeds with no error messages
--      Nothing, if m fails, or if it succeeds but has error messages
-- Either way, the messages are returned; even in the Just case
-- there might be warnings
tryTcErrs thing
  = do  { (msgs, res) <- tryTc thing
        ; dflags <- getDOpts
        ; let errs_found = errorsFound dflags msgs
        ; return (msgs, case res of
                          Nothing -> Nothing
                          Just val | errs_found -> Nothing
                                   | otherwise  -> Just val)
        }

-----------------------
tryTcLIE :: TcM a -> TcM (Messages, Maybe a)
-- Just like tryTcErrs, except that it ensures that the LIE
-- for the thing is propagated only if there are no errors
-- Hence it's restricted to the type-check monad
tryTcLIE thing_inside
  = do  { ((msgs, mb_res), lie) <- captureConstraints (tryTcErrs thing_inside) ;
        ; case mb_res of
            Nothing  -> return (msgs, Nothing)
            Just val -> do { emitConstraints lie; return (msgs, Just val) }
        }

-----------------------
tryTcLIE_ :: TcM r -> TcM r -> TcM r
-- (tryTcLIE_ r m) tries m;
--      if m succeeds with no error messages, it's the answer
--      otherwise tryTcLIE_ drops everything from m and tries r instead.
tryTcLIE_ recover main
  = do  { (msgs, mb_res) <- tryTcLIE main
        ; case mb_res of
             Just val -> do { addMessages msgs  -- There might be warnings
                             ; return val }
             Nothing  -> recover                -- Discard all msgs
        }

-----------------------
checkNoErrs :: TcM r -> TcM r
-- (checkNoErrs m) succeeds iff m succeeds and generates no errors
-- If m fails then (checkNoErrsTc m) fails.
-- If m succeeds, it checks whether m generated any errors messages
--      (it might have recovered internally)
--      If so, it fails too.
-- Regardless, any errors generated by m are propagated to the enclosing context.
checkNoErrs main
  = do  { (msgs, mb_res) <- tryTcLIE main
        ; addMessages msgs
        ; case mb_res of
            Nothing  -> failM
            Just val -> return val
        }

ifErrsM :: TcRn r -> TcRn r -> TcRn r
--      ifErrsM bale_out main
-- does 'bale_out' if there are errors in errors collection
-- otherwise does 'main'
ifErrsM bale_out normal
 = do { errs_var <- getErrsVar ;
        msgs <- readTcRef errs_var ;
        dflags <- getDOpts ;
        if errorsFound dflags msgs then
           bale_out
        else
           normal }

failIfErrsM :: TcRn ()
-- Useful to avoid error cascades
failIfErrsM = ifErrsM failM (return ())
\end{code}


%************************************************************************
%*                                                                      *
        Context management for the type checker
%*                                                                      *
%************************************************************************

\begin{code}
getErrCtxt :: TcM [ErrCtxt]
getErrCtxt = do { env <- getLclEnv; return (tcl_ctxt env) }

setErrCtxt :: [ErrCtxt] -> TcM a -> TcM a
setErrCtxt ctxt = updLclEnv (\ env -> env { tcl_ctxt = ctxt })

addErrCtxt :: Message -> TcM a -> TcM a
addErrCtxt msg = addErrCtxtM (\env -> return (env, msg))

addErrCtxtM :: (TidyEnv -> TcM (TidyEnv, Message)) -> TcM a -> TcM a
addErrCtxtM ctxt = updCtxt (\ ctxts -> (False, ctxt) : ctxts)

addLandmarkErrCtxt :: Message -> TcM a -> TcM a
addLandmarkErrCtxt msg = updCtxt (\ctxts -> (True, \env -> return (env,msg)) : ctxts)

-- Helper function for the above
updCtxt :: ([ErrCtxt] -> [ErrCtxt]) -> TcM a -> TcM a
updCtxt upd = updLclEnv (\ env@(TcLclEnv { tcl_ctxt = ctxt }) ->
                           env { tcl_ctxt = upd ctxt })

popErrCtxt :: TcM a -> TcM a
popErrCtxt = updCtxt (\ msgs -> case msgs of { [] -> []; (_ : ms) -> ms })

getCtLoc :: orig -> TcM (CtLoc orig)
getCtLoc origin
  = do { loc <- getSrcSpanM ; env <- getLclEnv ;
         return (CtLoc origin loc (tcl_ctxt env)) }

setCtLoc :: CtLoc orig -> TcM a -> TcM a
setCtLoc (CtLoc _ src_loc ctxt) thing_inside
  = setSrcSpan src_loc (setErrCtxt ctxt thing_inside)
\end{code}

%************************************************************************
%*                                                                      *
             Error message generation (type checker)
%*                                                                      *
%************************************************************************

    The addErrTc functions add an error message, but do not cause failure.
    The 'M' variants pass a TidyEnv that has already been used to
    tidy up the message; we then use it to tidy the context messages

\begin{code}
addErrTc :: Message -> TcM ()
addErrTc err_msg = do { env0 <- tcInitTidyEnv
                      ; addErrTcM (env0, err_msg) }

addErrsTc :: [Message] -> TcM ()
addErrsTc err_msgs = mapM_ addErrTc err_msgs

addErrTcM :: (TidyEnv, Message) -> TcM ()
addErrTcM (tidy_env, err_msg)
  = do { ctxt <- getErrCtxt ;
         loc  <- getSrcSpanM ;
         add_err_tcm tidy_env err_msg loc ctxt }
\end{code}

The failWith functions add an error message and cause failure

\begin{code}
failWithTc :: Message -> TcM a               -- Add an error message and fail
failWithTc err_msg
  = addErrTc err_msg >> failM

failWithTcM :: (TidyEnv, Message) -> TcM a   -- Add an error message and fail
failWithTcM local_and_msg
  = addErrTcM local_and_msg >> failM

checkTc :: Bool -> Message -> TcM ()         -- Check that the boolean is true
checkTc True  _   = return ()
checkTc False err = failWithTc err
\end{code}

        Warnings have no 'M' variant, nor failure

\begin{code}
addWarnTc :: Message -> TcM ()
addWarnTc msg = do { env0 <- tcInitTidyEnv
                   ; addWarnTcM (env0, msg) }

addWarnTcM :: (TidyEnv, Message) -> TcM ()
addWarnTcM (env0, msg)
 = do { ctxt <- getErrCtxt ;
        err_info <- mkErrInfo env0 ctxt ;
        addReport (ptext (sLit "Warning:") <+> msg) err_info }

warnTc :: Bool -> Message -> TcM ()
warnTc warn_if_true warn_msg
  | warn_if_true = addWarnTc warn_msg
  | otherwise    = return ()
\end{code}

-----------------------------------
         Tidying

We initialise the "tidy-env", used for tidying types before printing,
by building a reverse map from the in-scope type variables to the
OccName that the programmer originally used for them

\begin{code}
tcInitTidyEnv :: TcM TidyEnv
tcInitTidyEnv
  = do  { lcl_env <- getLclEnv
        ; let nm_tv_prs = [ (name, tcGetTyVar "tcInitTidyEnv" ty)
                          | ATyVar name ty <- nameEnvElts (tcl_env lcl_env)
                          , tcIsTyVarTy ty ]
        ; return (foldl add emptyTidyEnv nm_tv_prs) }
  where
    add (env,subst) (name, tyvar)
        = case tidyOccName env (nameOccName name) of
            (env', occ') ->  (env', extendVarEnv subst tyvar tyvar')
                where
                  tyvar' = setTyVarName tyvar name'
                  name'  = tidyNameOcc name occ'
\end{code}

-----------------------------------
        Other helper functions

\begin{code}
add_err_tcm :: TidyEnv -> Message -> SrcSpan
            -> [ErrCtxt]
            -> TcM ()
add_err_tcm tidy_env err_msg loc ctxt
 = do { err_info <- mkErrInfo tidy_env ctxt ;
        addLongErrAt loc err_msg err_info }

mkErrInfo :: TidyEnv -> [ErrCtxt] -> TcM SDoc
-- Tidy the error info, trimming excessive contexts
mkErrInfo env ctxts
 | opt_PprStyle_Debug     -- In -dppr-debug style the output
 = return empty           -- just becomes too voluminous
 | otherwise
 = go 0 env ctxts
 where
   go :: Int -> TidyEnv -> [ErrCtxt] -> TcM SDoc
   go _ _   [] = return empty
   go n env ((is_landmark, ctxt) : ctxts)
     | is_landmark || n < mAX_CONTEXTS -- Too verbose || opt_PprStyle_Debug
     = do { (env', msg) <- ctxt env
          ; let n' = if is_landmark then n else n+1
          ; rest <- go n' env' ctxts
          ; return (msg $$ rest) }
     | otherwise
     = go n env ctxts

mAX_CONTEXTS :: Int     -- No more than this number of non-landmark contexts
mAX_CONTEXTS = 3
\end{code}

debugTc is useful for monadic debugging code

\begin{code}
debugTc :: TcM () -> TcM ()
debugTc thing
 | debugIsOn = thing
 | otherwise = return ()
\end{code}

%************************************************************************
%*                                                                      *
             Type constraints
%*                                                                      *
%************************************************************************

\begin{code}
newTcEvBinds :: TcM EvBindsVar
newTcEvBinds = do { ref <- newTcRef emptyEvBindMap
                  ; uniq <- newUnique
                  ; return (EvBindsVar ref uniq) }

addTcEvBind :: EvBindsVar -> EvVar -> EvTerm -> TcM ()
-- Add a binding to the TcEvBinds by side effect
addTcEvBind (EvBindsVar ev_ref _) var t
  = do { bnds <- readTcRef ev_ref
       ; writeTcRef ev_ref (extendEvBinds bnds var t) }

chooseUniqueOccTc :: (OccSet -> OccName) -> TcM OccName
chooseUniqueOccTc fn =
  do { env <- getGblEnv
     ; let dfun_n_var = tcg_dfun_n env
     ; set <- readTcRef dfun_n_var
     ; let occ = fn set
     ; writeTcRef dfun_n_var (extendOccSet set occ)
     ; return occ }

getConstraintVar :: TcM (TcRef WantedConstraints)
getConstraintVar = do { env <- getLclEnv; return (tcl_lie env) }

setConstraintVar :: TcRef WantedConstraints -> TcM a -> TcM a
setConstraintVar lie_var = updLclEnv (\ env -> env { tcl_lie = lie_var })

emitConstraints :: WantedConstraints -> TcM ()
emitConstraints ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`andWC` ct) }

emitFlat :: WantedEvVar -> TcM ()
emitFlat ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addFlats` unitBag ct) }

emitFlats :: Bag WantedEvVar -> TcM ()
emitFlats ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addFlats` ct) }

emitWantedCts :: Cts -> TcM () 
-- Precondition: all wanted
emitWantedCts = mapBagM_ emit_wanted_ct
  where emit_wanted_ct ct 
          | v <- cc_id ct 
          , Wanted loc <- cc_flavor ct 
          = emitFlat (EvVarX v loc)
          | otherwise = panic "emitWantedCts: can't emit non-wanted!"

emitImplication :: Implication -> TcM ()
emitImplication ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addImplics` unitBag ct) }

emitImplications :: Bag Implication -> TcM ()
emitImplications ct
  = do { lie_var <- getConstraintVar ;
         updTcRef lie_var (`addImplics` ct) }

captureConstraints :: TcM a -> TcM (a, WantedConstraints)
-- (captureConstraints m) runs m, and returns the type constraints it generates
captureConstraints thing_inside
  = do { lie_var <- newTcRef emptyWC ;
         res <- updLclEnv (\ env -> env { tcl_lie = lie_var })
                          thing_inside ;
         lie <- readTcRef lie_var ;
         return (res, lie) }

captureUntouchables :: TcM a -> TcM (a, Untouchables)
captureUntouchables thing_inside
  = do { env <- getLclEnv
       ; low_meta <- readTcRef (tcl_meta env)
       ; res <- setLclEnv (env { tcl_untch = low_meta })
                thing_inside
       ; high_meta <- readTcRef (tcl_meta env)
       ; return (res, TouchableRange low_meta high_meta) }

isUntouchable :: TcTyVar -> TcM Bool
isUntouchable tv = do { env <- getLclEnv
                      ; return (varUnique tv < tcl_untch env) }

getLclTypeEnv :: TcM TcTypeEnv
getLclTypeEnv = do { env <- getLclEnv; return (tcl_env env) }

setLclTypeEnv :: TcLclEnv -> TcM a -> TcM a
-- Set the local type envt, but do *not* disturb other fields,
-- notably the lie_var
setLclTypeEnv lcl_env thing_inside
  = updLclEnv upd thing_inside
  where
    upd env = env { tcl_env = tcl_env lcl_env,
                    tcl_tyvars = tcl_tyvars lcl_env }

traceTcConstraints :: String -> TcM ()
traceTcConstraints msg
  = do { lie_var <- getConstraintVar
       ; lie     <- readTcRef lie_var
       ; traceTc (msg ++ "LIE:") (ppr lie)
       }
\end{code}


%************************************************************************
%*                                                                      *
             Template Haskell context
%*                                                                      *
%************************************************************************

\begin{code}
recordThUse :: TcM ()
recordThUse = do { env <- getGblEnv; writeTcRef (tcg_th_used env) True }

recordThSpliceUse :: TcM ()
recordThSpliceUse = do { env <- getGblEnv; writeTcRef (tcg_th_splice_used env) True }

keepAliveTc :: Id -> TcM ()     -- Record the name in the keep-alive set
keepAliveTc id
  | isLocalId id = do { env <- getGblEnv;
                      ; updTcRef (tcg_keep env) (`addOneToNameSet` idName id) }
  | otherwise = return ()

keepAliveSetTc :: NameSet -> TcM ()     -- Record the name in the keep-alive set
keepAliveSetTc ns = do { env <- getGblEnv;
                       ; updTcRef (tcg_keep env) (`unionNameSets` ns) }

getStage :: TcM ThStage
getStage = do { env <- getLclEnv; return (tcl_th_ctxt env) }

setStage :: ThStage -> TcM a -> TcM a
setStage s = updLclEnv (\ env -> env { tcl_th_ctxt = s })
\end{code}


%************************************************************************
%*                                                                      *
             Safe Haskell context
%*                                                                      *
%************************************************************************

\begin{code}
-- | Mark that safe inference has failed
recordUnsafeInfer :: TcM ()
recordUnsafeInfer = getGblEnv >>= \env -> writeTcRef (tcg_safeInfer env) False

-- | Figure out the final correct safe haskell mode
finalSafeMode :: DynFlags -> TcGblEnv -> IO SafeHaskellMode
finalSafeMode dflags tcg_env = do
    safeInf <- readIORef (tcg_safeInfer tcg_env)
    return $ if safeInferOn dflags && not safeInf
        then Sf_None
        else safeHaskell dflags
\end{code}


%************************************************************************
%*                                                                      *
             Stuff for the renamer's local env
%*                                                                      *
%************************************************************************

\begin{code}
getLocalRdrEnv :: RnM LocalRdrEnv
getLocalRdrEnv = do { env <- getLclEnv; return (tcl_rdr env) }

setLocalRdrEnv :: LocalRdrEnv -> RnM a -> RnM a
setLocalRdrEnv rdr_env thing_inside
  = updLclEnv (\env -> env {tcl_rdr = rdr_env}) thing_inside
\end{code}


%************************************************************************
%*                                                                      *
             Stuff for interface decls
%*                                                                      *
%************************************************************************

\begin{code}
mkIfLclEnv :: Module -> SDoc -> IfLclEnv
mkIfLclEnv mod loc = IfLclEnv { if_mod     = mod,
                                if_loc     = loc,
                                if_tv_env  = emptyUFM,
                                if_id_env  = emptyUFM }

initIfaceTcRn :: IfG a -> TcRn a
initIfaceTcRn thing_inside
  = do  { tcg_env <- getGblEnv
        ; let { if_env = IfGblEnv { if_rec_types = Just (tcg_mod tcg_env, get_type_env) }
              ; get_type_env = readTcRef (tcg_type_env_var tcg_env) }
        ; setEnvs (if_env, ()) thing_inside }

initIfaceExtCore :: IfL a -> TcRn a
initIfaceExtCore thing_inside
  = do  { tcg_env <- getGblEnv
        ; let { mod = tcg_mod tcg_env
              ; doc = ptext (sLit "External Core file for") <+> quotes (ppr mod)
              ; if_env = IfGblEnv {
                        if_rec_types = Just (mod, return (tcg_type_env tcg_env)) }
              ; if_lenv = mkIfLclEnv mod doc
          }
        ; setEnvs (if_env, if_lenv) thing_inside }

initIfaceCheck :: HscEnv -> IfG a -> IO a
-- Used when checking the up-to-date-ness of the old Iface
-- Initialise the environment with no useful info at all
initIfaceCheck hsc_env do_this
 = do let rec_types = case hsc_type_env_var hsc_env of
                         Just (mod,var) -> Just (mod, readTcRef var)
                         Nothing        -> Nothing
          gbl_env = IfGblEnv { if_rec_types = rec_types }
      initTcRnIf 'i' hsc_env gbl_env () do_this

initIfaceTc :: ModIface
            -> (TcRef TypeEnv -> IfL a) -> TcRnIf gbl lcl a
-- Used when type-checking checking an up-to-date interface file
-- No type envt from the current module, but we do know the module dependencies
initIfaceTc iface do_this
 = do   { tc_env_var <- newTcRef emptyTypeEnv
        ; let { gbl_env = IfGblEnv { if_rec_types = Just (mod, readTcRef tc_env_var) } ;
              ; if_lenv = mkIfLclEnv mod doc
           }
        ; setEnvs (gbl_env, if_lenv) (do_this tc_env_var)
    }
  where
    mod = mi_module iface
    doc = ptext (sLit "The interface for") <+> quotes (ppr mod)

initIfaceLcl :: Module -> SDoc -> IfL a -> IfM lcl a
initIfaceLcl mod loc_doc thing_inside
  = setLclEnv (mkIfLclEnv mod loc_doc) thing_inside

getIfModule :: IfL Module
getIfModule = do { env <- getLclEnv; return (if_mod env) }

--------------------
failIfM :: Message -> IfL a
-- The Iface monad doesn't have a place to accumulate errors, so we
-- just fall over fast if one happens; it "shouldnt happen".
-- We use IfL here so that we can get context info out of the local env
failIfM msg
  = do  { env <- getLclEnv
        ; let full_msg = (if_loc env <> colon) $$ nest 2 msg
        ; liftIO (printErrs full_msg defaultErrStyle)
        ; failM }

--------------------
forkM_maybe :: SDoc -> IfL a -> IfL (Maybe a)
-- Run thing_inside in an interleaved thread.
-- It shares everything with the parent thread, so this is DANGEROUS.
--
-- It returns Nothing if the computation fails
--
-- It's used for lazily type-checking interface
-- signatures, which is pretty benign

forkM_maybe doc thing_inside
 = do { unsafeInterleaveM $
        do { traceIf (text "Starting fork {" <+> doc)
           ; mb_res <- tryM $
                       updLclEnv (\env -> env { if_loc = if_loc env $$ doc }) $
                       thing_inside
           ; case mb_res of
                Right r  -> do  { traceIf (text "} ending fork" <+> doc)
                                ; return (Just r) }
                Left exn -> do {

                    -- Bleat about errors in the forked thread, if -ddump-if-trace is on
                    -- Otherwise we silently discard errors. Errors can legitimately
                    -- happen when compiling interface signatures (see tcInterfaceSigs)
                      ifDOptM Opt_D_dump_if_trace
                             (print_errs (hang (text "forkM failed:" <+> doc)
                                             2 (text (show exn))))

                    ; traceIf (text "} ending fork (badly)" <+> doc)
                    ; return Nothing }
        }}
  where
    print_errs sdoc = liftIO (printErrs sdoc defaultErrStyle)

forkM :: SDoc -> IfL a -> IfL a
forkM doc thing_inside
 = do   { mb_res <- forkM_maybe doc thing_inside
        ; return (case mb_res of
                        Nothing -> pgmError "Cannot continue after interface file error"
                                   -- pprPanic "forkM" doc
                        Just r  -> r) }
\end{code}
