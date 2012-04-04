{-# OPTIONS -fno-warn-type-defaults #-}
-- ----------------------------------------------------------------------------
-- | Handle conversion of CmmProc to LLVM code.
--

module LlvmCodeGen.CodeGen ( genLlvmProc ) where

#include "HsVersions.h"

import Llvm
import LlvmCodeGen.Base
import LlvmCodeGen.Regs

import BlockId
import CgUtils ( activeStgRegs, callerSaves )
import CLabel
import OldCmm
import qualified OldPprCmm as PprCmm
import OrdList

import FastString
import ForeignCall
import Outputable hiding ( panic, pprPanic )
import qualified Outputable
import Platform
import UniqSupply
import Unique
import Util

import Data.List ( partition )


type LlvmStatements = OrdList LlvmStatement

-- -----------------------------------------------------------------------------
-- | Top-level of the LLVM proc Code generator
--
genLlvmProc :: LlvmEnv -> RawCmmDecl -> UniqSM (LlvmEnv, [LlvmCmmDecl])
genLlvmProc env (CmmProc info lbl (ListGraph blocks)) = do
    (env', lmblocks, lmdata) <- basicBlocksCodeGen env blocks ([], [])
    let proc = CmmProc info lbl (ListGraph lmblocks)
    return (env', proc:lmdata)

genLlvmProc _ _ = panic "genLlvmProc: case that shouldn't reach here!"

-- -----------------------------------------------------------------------------
-- * Block code generation
--

-- | Generate code for a list of blocks that make up a complete procedure.
basicBlocksCodeGen :: LlvmEnv
                   -> [CmmBasicBlock]
                   -> ( [LlvmBasicBlock] , [LlvmCmmDecl] )
                   -> UniqSM (LlvmEnv, [LlvmBasicBlock] , [LlvmCmmDecl] )
basicBlocksCodeGen env ([]) (blocks, tops)
  = do let (blocks', allocs) = mapAndUnzip dominateAllocs blocks
       let allocs' = concat allocs
       let ((BasicBlock id fstmts):rblks) = blocks'
       let fblocks = (BasicBlock id $ funPrologue ++  allocs' ++ fstmts):rblks
       return (env, fblocks, tops)

basicBlocksCodeGen env (block:blocks) (lblocks', ltops')
  = do (env', lb, lt) <- basicBlockCodeGen env block
       let lblocks = lblocks' ++ lb
       let ltops   = ltops' ++ lt
       basicBlocksCodeGen env' blocks (lblocks, ltops)


-- | Allocations need to be extracted so they can be moved to the entry
-- of a function to make sure they dominate all possible paths in the CFG.
dominateAllocs :: LlvmBasicBlock -> (LlvmBasicBlock, [LlvmStatement])
dominateAllocs (BasicBlock id stmts)
  = let (allocs, stmts') = partition isAlloc stmts
        isAlloc (Assignment _ (Alloca _ _)) = True
        isAlloc _other                      = False
    in (BasicBlock id stmts', allocs)


-- | Generate code for one block
basicBlockCodeGen ::  LlvmEnv
                  -> CmmBasicBlock
                  -> UniqSM ( LlvmEnv, [LlvmBasicBlock], [LlvmCmmDecl] )
basicBlockCodeGen env (BasicBlock id stmts)
  = do (env', instrs, top) <- stmtsToInstrs env stmts (nilOL, [])
       return (env', [BasicBlock id (fromOL instrs)], top)


-- -----------------------------------------------------------------------------
-- * CmmStmt code generation
--

-- A statement conversion return data.
--   * LlvmEnv: The new environment
--   * LlvmStatements: The compiled LLVM statements.
--   * LlvmCmmDecl: Any global data needed.
type StmtData = (LlvmEnv, LlvmStatements, [LlvmCmmDecl])


-- | Convert a list of CmmStmt's to LlvmStatement's
stmtsToInstrs :: LlvmEnv -> [CmmStmt] -> (LlvmStatements, [LlvmCmmDecl])
              -> UniqSM StmtData
stmtsToInstrs env [] (llvm, top)
  = return (env, llvm, top)

stmtsToInstrs env (stmt : stmts) (llvm, top)
   = do (env', instrs, tops) <- stmtToInstrs env stmt
        stmtsToInstrs env' stmts (llvm `appOL` instrs, top ++ tops)


-- | Convert a CmmStmt to a list of LlvmStatement's
stmtToInstrs :: LlvmEnv -> CmmStmt
             -> UniqSM StmtData
stmtToInstrs env stmt = case stmt of

    CmmNop               -> return (env, nilOL, [])
    CmmComment _         -> return (env, nilOL, []) -- nuke comments

    CmmAssign reg src    -> genAssign env reg src
    CmmStore addr src    -> genStore env addr src

    CmmBranch id         -> genBranch env id
    CmmCondBranch arg id -> genCondBranch env arg id
    CmmSwitch arg ids    -> genSwitch env arg ids

    -- Foreign Call
    CmmCall target res args ret
        -> genCall env target res args ret

    -- Tail call
    CmmJump arg _ -> genJump env arg

    -- CPS, only tail calls, no return's
    -- Actually, there are a few return statements that occur because of hand
    -- written Cmm code.
    CmmReturn _
        -> return (env, unitOL $ Return Nothing, [])


-- | Memory barrier instruction for LLVM >= 3.0
barrier :: LlvmEnv -> UniqSM StmtData
barrier env = do
    let s = Fence False SyncSeqCst
    return (env, unitOL s, [])

-- | Memory barrier instruction for LLVM < 3.0
oldBarrier :: LlvmEnv -> UniqSM StmtData
oldBarrier env = do
    let fname = fsLit "llvm.memory.barrier"
    let funSig = LlvmFunctionDecl fname ExternallyVisible CC_Ccc LMVoid
                    FixedArgs (tysToParams [i1, i1, i1, i1, i1]) llvmFunAlign
    let fty = LMFunction funSig

    let fv   = LMGlobalVar fname fty (funcLinkage funSig) Nothing Nothing False
    let tops = case funLookup fname env of
                    Just _  -> []
                    Nothing -> [CmmData Data [([],[fty])]]

    let args = [lmTrue, lmTrue, lmTrue, lmTrue, lmTrue]
    let s1 = Expr $ Call StdCall fv args llvmStdFunAttrs
    let env' = funInsert fname fty env

    return (env', unitOL s1, tops)

    where
        lmTrue :: LlvmVar
        lmTrue  = mkIntLit i1 (-1)

-- | Foreign Calls
genCall :: LlvmEnv -> CmmCallTarget -> [HintedCmmFormal] -> [HintedCmmActual]
              -> CmmReturnInfo -> UniqSM StmtData

-- Write barrier needs to be handled specially as it is implemented as an LLVM
-- intrinsic function.
genCall env (CmmPrim MO_WriteBarrier) _ _ _
 | platformArch (getLlvmPlatform env) `elem` [ArchX86, ArchX86_64, ArchSPARC]
    = return (env, nilOL, [])
 | getLlvmVer env > 29 = barrier env
 | otherwise           = oldBarrier env

-- Handle popcnt function specifically since GHC only really has i32 and i64
-- types and things like Word8 are backed by an i32 and just present a logical
-- i8 range. So we must handle conversions from i32 to i8 explicitly as LLVM
-- is strict about types.
genCall env t@(CmmPrim (MO_PopCnt w)) [CmmHinted dst _] args _ = do
    let width = widthToLlvmInt w
        dstTy = cmmToLlvmType $ localRegType dst
        funTy = \n -> LMFunction $ LlvmFunctionDecl n ExternallyVisible
                          CC_Ccc width FixedArgs (tysToParams [width]) Nothing
        (env1, dstV, stmts1, top1) = getCmmReg env (CmmLocal dst)

    (env2, argsV, stmts2, top2) <- arg_vars env1 args ([], nilOL, [])
    (env3, fptr, stmts3, top3)  <- getFunPtr env2 funTy t
    (argsV', stmts4)            <- castVars $ zip argsV [width]
    (retV, s1)                  <- doExpr width $ Call StdCall fptr argsV' []
    ([retV'], stmts5)           <- castVars [(retV,dstTy)]
    let s2                       = Store retV' dstV

    let stmts = stmts1 `appOL` stmts2 `appOL` stmts3 `appOL` stmts4 `snocOL`
                s1 `appOL` stmts5 `snocOL` s2
    return (env3, stmts, top1 ++ top2 ++ top3)

-- Handle memcpy function specifically since llvm's intrinsic version takes
-- some extra parameters.
genCall env t@(CmmPrim op) [] args CmmMayReturn | op == MO_Memcpy ||
                                                  op == MO_Memset ||
                                                  op == MO_Memmove = do
    let (isVolTy, isVolVal) = if getLlvmVer env >= 28
                                 then ([i1], [mkIntLit i1 0]) else ([], [])
        argTy | op == MO_Memset = [i8Ptr, i8,    llvmWord, i32] ++ isVolTy
              | otherwise       = [i8Ptr, i8Ptr, llvmWord, i32] ++ isVolTy
        funTy = \name -> LMFunction $ LlvmFunctionDecl name ExternallyVisible
                             CC_Ccc LMVoid FixedArgs (tysToParams argTy) Nothing

    (env1, argVars, stmts1, top1) <- arg_vars env args ([], nilOL, [])
    (env2, fptr, stmts2, top2)    <- getFunPtr env1 funTy t
    (argVars', stmts3)            <- castVars $ zip argVars argTy

    let arguments = argVars' ++ isVolVal
        call = Expr $ Call StdCall fptr arguments []
        stmts = stmts1 `appOL` stmts2 `appOL` stmts3
                `appOL` trashStmts `snocOL` call
    return (env2, stmts, top1 ++ top2)

-- Handle all other foreign calls and prim ops.
genCall env target res args ret = do

    -- parameter types
    let arg_type (CmmHinted _ AddrHint) = i8Ptr
        -- cast pointers to i8*. Llvm equivalent of void*
        arg_type (CmmHinted expr _    ) = cmmToLlvmType $ cmmExprType expr

    -- ret type
    let ret_type ([]) = LMVoid
        ret_type ([CmmHinted _ AddrHint]) = i8Ptr
        ret_type ([CmmHinted reg _])      = cmmToLlvmType $ localRegType reg
        ret_type t = panic $ "genCall: Too many return values! Can only handle"
                        ++ " 0 or 1, given " ++ show (length t) ++ "."

    -- extract Cmm call convention
    let cconv = case target of
            CmmCallee _ conv -> conv
            CmmPrim   _      -> PrimCallConv

    -- translate to LLVM call convention
    let lmconv = case cconv of
            StdCallConv  -> case platformArch (getLlvmPlatform env) of
                            ArchX86    -> CC_X86_Stdcc
                            ArchX86_64 -> CC_X86_Stdcc
                            _          -> CC_Ccc
            CCallConv    -> CC_Ccc
            CApiConv     -> CC_Ccc
            PrimCallConv -> CC_Ccc
            CmmCallConv  -> panic "CmmCallConv not supported here!"

    {-
        Some of the possibilities here are a worry with the use of a custom
        calling convention for passing STG args. In practice the more
        dangerous combinations (e.g StdCall + llvmGhcCC) don't occur.

        The native code generator only handles StdCall and CCallConv.
    -}

    -- call attributes
    let fnAttrs | ret == CmmNeverReturns = NoReturn : llvmStdFunAttrs
                | otherwise              = llvmStdFunAttrs

    -- fun type
    let ccTy  = StdCall -- tail calls should be done through CmmJump
    let retTy = ret_type res
    let argTy = tysToParams $ map arg_type args
    let funTy = \name -> LMFunction $ LlvmFunctionDecl name ExternallyVisible
                             lmconv retTy FixedArgs argTy llvmFunAlign


    (env1, argVars, stmts1, top1) <- arg_vars env args ([], nilOL, [])
    (env2, fptr, stmts2, top2)    <- getFunPtr env1 funTy target

    let retStmt | ccTy == TailCall       = unitOL $ Return Nothing
                | ret == CmmNeverReturns = unitOL $ Unreachable
                | otherwise              = nilOL

    let stmts = stmts1 `appOL` stmts2 `appOL` trashStmts

    -- make the actual call
    case retTy of
        LMVoid -> do
            let s1 = Expr $ Call ccTy fptr argVars fnAttrs
            let allStmts = stmts `snocOL` s1 `appOL` retStmt
            return (env2, allStmts, top1 ++ top2)

        _ -> do
            (v1, s1) <- doExpr retTy $ Call ccTy fptr argVars fnAttrs
            -- get the return register
            let ret_reg ([CmmHinted reg hint]) = (reg, hint)
                ret_reg t = panic $ "genCall: Bad number of registers! Can only handle"
                                ++ " 1, given " ++ show (length t) ++ "."
            let (creg, _) = ret_reg res
            let (env3, vreg, stmts3, top3) = getCmmReg env2 (CmmLocal creg)
            let allStmts = stmts `snocOL` s1 `appOL` stmts3
            if retTy == pLower (getVarType vreg)
                then do
                    let s2 = Store v1 vreg
                    return (env3, allStmts `snocOL` s2 `appOL` retStmt,
                                top1 ++ top2 ++ top3)
                else do
                    let ty = pLower $ getVarType vreg
                    let op = case ty of
                            vt | isPointer vt -> LM_Bitcast
                               | isInt     vt -> LM_Ptrtoint
                               | otherwise    ->
                                   panic $ "genCall: CmmReg bad match for"
                                        ++ " returned type!"

                    (v2, s2) <- doExpr ty $ Cast op v1 ty
                    let s3 = Store v2 vreg
                    return (env3, allStmts `snocOL` s2 `snocOL` s3
                                `appOL` retStmt, top1 ++ top2 ++ top3)


-- | Create a function pointer from a target.
getFunPtr :: LlvmEnv -> (LMString -> LlvmType) -> CmmCallTarget
          -> UniqSM ExprData
getFunPtr env funTy targ = case targ of
    CmmCallee (CmmLit (CmmLabel lbl)) _ -> litCase $ strCLabel_llvm env lbl

    CmmCallee expr _ -> do
        (env', v1, stmts, top) <- exprToVar env expr
        let fty = funTy $ fsLit "dynamic"
            cast = case getVarType v1 of
                ty | isPointer ty -> LM_Bitcast
                ty | isInt ty     -> LM_Inttoptr

                ty -> panic $ "genCall: Expr is of bad type for function"
                              ++ " call! (" ++ show (ty) ++ ")"

        (v2,s1) <- doExpr (pLift fty) $ Cast cast v1 (pLift fty)
        return (env', v2, stmts `snocOL` s1, top)

    CmmPrim mop -> litCase $ cmmPrimOpFunctions env mop

    where
        litCase name = do
            case funLookup name env of
                Just ty'@(LMFunction sig) -> do
                    -- Function in module in right form
                    let fun = LMGlobalVar name ty' (funcLinkage sig)
                                    Nothing Nothing False
                    return (env, fun, nilOL, [])

                Just ty' -> do
                    -- label in module but not function pointer, convert
                    let fty@(LMFunction sig) = funTy name
                        fun = LMGlobalVar name (pLift ty') (funcLinkage sig)
                                    Nothing Nothing False
                    (v1, s1) <- doExpr (pLift fty)
                                    $ Cast LM_Bitcast fun (pLift fty)
                    return  (env, v1, unitOL s1, [])

                Nothing -> do
                    -- label not in module, create external reference
                    let fty@(LMFunction sig) = funTy name
                        fun = LMGlobalVar name fty (funcLinkage sig)
                                    Nothing Nothing False
                        top = [CmmData Data [([],[fty])]]
                        env' = funInsert name fty env
                    return (env', fun, nilOL, top)


-- | Conversion of call arguments.
arg_vars :: LlvmEnv
         -> [HintedCmmActual]
         -> ([LlvmVar], LlvmStatements, [LlvmCmmDecl])
         -> UniqSM (LlvmEnv, [LlvmVar], LlvmStatements, [LlvmCmmDecl])

arg_vars env [] (vars, stmts, tops)
  = return (env, vars, stmts, tops)

arg_vars env (CmmHinted e AddrHint:rest) (vars, stmts, tops)
  = do (env', v1, stmts', top') <- exprToVar env e
       let op = case getVarType v1 of
               ty | isPointer ty -> LM_Bitcast
               ty | isInt ty     -> LM_Inttoptr

               a  -> panic $ "genCall: Can't cast llvmType to i8*! ("
                           ++ show a ++ ")"

       (v2, s1) <- doExpr i8Ptr $ Cast op v1 i8Ptr
       arg_vars env' rest (vars ++ [v2], stmts `appOL` stmts' `snocOL` s1,
                               tops ++ top')

arg_vars env (CmmHinted e _:rest) (vars, stmts, tops)
  = do (env', v1, stmts', top') <- exprToVar env e
       arg_vars env' rest (vars ++ [v1], stmts `appOL` stmts', tops ++ top')


-- | Cast a collection of LLVM variables to specific types.
castVars :: [(LlvmVar, LlvmType)]
         -> UniqSM ([LlvmVar], LlvmStatements)
castVars vars = do
                done <- mapM (uncurry castVar) vars
                let (vars', stmts) = unzip done
                return (vars', toOL stmts)

-- | Cast an LLVM variable to a specific type, panicing if it can't be done.
castVar :: LlvmVar -> LlvmType -> UniqSM (LlvmVar, LlvmStatement)
castVar v t | getVarType v == t
            = return (v, Nop)

            | otherwise
            = let op = case (getVarType v, t) of
                      (LMInt n, LMInt m)
                          -> if n < m then LM_Sext else LM_Trunc
                      (vt, _) | isFloat vt && isFloat t
                          -> if llvmWidthInBits vt < llvmWidthInBits t
                                then LM_Fpext else LM_Fptrunc
                      (vt, _) | isInt vt && isFloat t       -> LM_Sitofp
                      (vt, _) | isFloat vt && isInt t       -> LM_Fptosi
                      (vt, _) | isInt vt && isPointer t     -> LM_Inttoptr
                      (vt, _) | isPointer vt && isInt t     -> LM_Ptrtoint
                      (vt, _) | isPointer vt && isPointer t -> LM_Bitcast

                      (vt, _) -> panic $ "castVars: Can't cast this type ("
                                  ++ show vt ++ ") to (" ++ show t ++ ")"
              in doExpr t $ Cast op v t


-- | Decide what C function to use to implement a CallishMachOp
cmmPrimOpFunctions :: LlvmEnv -> CallishMachOp -> LMString
cmmPrimOpFunctions env mop
 = case mop of
    MO_F32_Exp    -> fsLit "expf"
    MO_F32_Log    -> fsLit "logf"
    MO_F32_Sqrt   -> fsLit "llvm.sqrt.f32"
    MO_F32_Pwr    -> fsLit "llvm.pow.f32"

    MO_F32_Sin    -> fsLit "llvm.sin.f32"
    MO_F32_Cos    -> fsLit "llvm.cos.f32"
    MO_F32_Tan    -> fsLit "tanf"

    MO_F32_Asin   -> fsLit "asinf"
    MO_F32_Acos   -> fsLit "acosf"
    MO_F32_Atan   -> fsLit "atanf"

    MO_F32_Sinh   -> fsLit "sinhf"
    MO_F32_Cosh   -> fsLit "coshf"
    MO_F32_Tanh   -> fsLit "tanhf"

    MO_F64_Exp    -> fsLit "exp"
    MO_F64_Log    -> fsLit "log"
    MO_F64_Sqrt   -> fsLit "llvm.sqrt.f64"
    MO_F64_Pwr    -> fsLit "llvm.pow.f64"

    MO_F64_Sin    -> fsLit "llvm.sin.f64"
    MO_F64_Cos    -> fsLit "llvm.cos.f64"
    MO_F64_Tan    -> fsLit "tan"

    MO_F64_Asin   -> fsLit "asin"
    MO_F64_Acos   -> fsLit "acos"
    MO_F64_Atan   -> fsLit "atan"

    MO_F64_Sinh   -> fsLit "sinh"
    MO_F64_Cosh   -> fsLit "cosh"
    MO_F64_Tanh   -> fsLit "tanh"

    MO_Memcpy     -> fsLit $ "llvm.memcpy."  ++ intrinTy1
    MO_Memmove    -> fsLit $ "llvm.memmove." ++ intrinTy1
    MO_Memset     -> fsLit $ "llvm.memset."  ++ intrinTy2

    (MO_PopCnt w) -> fsLit $ "llvm.ctpop."  ++ show (widthToLlvmInt w)

    MO_WriteBarrier ->
        panic $ "cmmPrimOpFunctions: MO_WriteBarrier not supported here"
    MO_Touch ->
        panic $ "cmmPrimOpFunctions: MO_Touch not supported here"

    where
        intrinTy1 = (if getLlvmVer env >= 28
                       then "p0i8.p0i8." else "") ++ show llvmWord
        intrinTy2 = (if getLlvmVer env >= 28
                       then "p0i8." else "") ++ show llvmWord
    

-- | Tail function calls
genJump :: LlvmEnv -> CmmExpr -> UniqSM StmtData

-- Call to known function
genJump env (CmmLit (CmmLabel lbl)) = do
    (env', vf, stmts, top) <- getHsFunc env lbl
    (stgRegs, stgStmts) <- funEpilogue
    let s1  = Expr $ Call TailCall vf stgRegs llvmStdFunAttrs
    let s2  = Return Nothing
    return (env', stmts `appOL` stgStmts `snocOL` s1 `snocOL` s2, top)


-- Call to unknown function / address
genJump env expr = do
    let fty = llvmFunTy
    (env', vf, stmts, top) <- exprToVar env expr

    let cast = case getVarType vf of
         ty | isPointer ty -> LM_Bitcast
         ty | isInt ty     -> LM_Inttoptr

         ty -> panic $ "genJump: Expr is of bad type for function call! ("
                     ++ show (ty) ++ ")"

    (v1, s1) <- doExpr (pLift fty) $ Cast cast vf (pLift fty)
    (stgRegs, stgStmts) <- funEpilogue
    let s2 = Expr $ Call TailCall v1 stgRegs llvmStdFunAttrs
    let s3 = Return Nothing
    return (env', stmts `snocOL` s1 `appOL` stgStmts `snocOL` s2 `snocOL` s3,
            top)


-- | CmmAssign operation
--
-- We use stack allocated variables for CmmReg. The optimiser will replace
-- these with registers when possible.
genAssign :: LlvmEnv -> CmmReg -> CmmExpr -> UniqSM StmtData
genAssign env reg val = do
    let (env1, vreg, stmts1, top1) = getCmmReg env reg
    (env2, vval, stmts2, top2) <- exprToVar env1 val
    let stmts = stmts1 `appOL` stmts2

    let ty = (pLower . getVarType) vreg
    case isPointer ty && getVarType vval == llvmWord of
         -- Some registers are pointer types, so need to cast value to pointer
         True -> do
             (v, s1) <- doExpr ty $ Cast LM_Inttoptr vval ty
             let s2 = Store v vreg
             return (env2, stmts `snocOL` s1 `snocOL` s2, top1 ++ top2)

         False -> do
             let s1 = Store vval vreg
             return (env2, stmts `snocOL` s1, top1 ++ top2)


-- | CmmStore operation
genStore :: LlvmEnv -> CmmExpr -> CmmExpr -> UniqSM StmtData

-- First we try to detect a few common cases and produce better code for
-- these then the default case. We are mostly trying to detect Cmm code
-- like I32[Sp + n] and use 'getelementptr' operations instead of the
-- generic case that uses casts and pointer arithmetic
genStore env addr@(CmmReg (CmmGlobal r)) val
    = genStore_fast env addr r 0 val

genStore env addr@(CmmRegOff (CmmGlobal r) n) val
    = genStore_fast env addr r n val

genStore env addr@(CmmMachOp (MO_Add _) [
                            (CmmReg (CmmGlobal r)),
                            (CmmLit (CmmInt n _))])
                val
    = genStore_fast env addr r (fromInteger n) val

genStore env addr@(CmmMachOp (MO_Sub _) [
                            (CmmReg (CmmGlobal r)),
                            (CmmLit (CmmInt n _))])
                val
    = genStore_fast env addr r (negate $ fromInteger n) val

-- generic case
genStore env addr val = genStore_slow env addr val

-- | CmmStore operation
-- This is a special case for storing to a global register pointer
-- offset such as I32[Sp+8].
genStore_fast :: LlvmEnv -> CmmExpr -> GlobalReg -> Int -> CmmExpr
              -> UniqSM StmtData
genStore_fast env addr r n val
  = let gr  = lmGlobalRegVar r
        grt = (pLower . getVarType) gr
        (ix,rem) = n `divMod` ((llvmWidthInBits . pLower) grt  `div` 8)
    in case isPointer grt && rem == 0 of
            True -> do
                (env', vval,  stmts, top) <- exprToVar env val
                (gv,  s1) <- doExpr grt $ Load gr
                (ptr, s2) <- doExpr grt $ GetElemPtr True gv [toI32 ix]
                -- We might need a different pointer type, so check
                case pLower grt == getVarType vval of
                     -- were fine
                     True  -> do
                         let s3 = Store vval ptr
                         return (env',  stmts `snocOL` s1 `snocOL` s2
                                 `snocOL` s3, top)

                     -- cast to pointer type needed
                     False -> do
                         let ty = (pLift . getVarType) vval
                         (ptr', s3) <- doExpr ty $ Cast LM_Bitcast ptr ty
                         let s4 = Store vval ptr'
                         return (env',  stmts `snocOL` s1 `snocOL` s2
                                 `snocOL` s3 `snocOL` s4, top)

            -- If its a bit type then we use the slow method since
            -- we can't avoid casting anyway.
            False -> genStore_slow env addr val


-- | CmmStore operation
-- Generic case. Uses casts and pointer arithmetic if needed.
genStore_slow :: LlvmEnv -> CmmExpr -> CmmExpr -> UniqSM StmtData
genStore_slow env addr val = do
    (env1, vaddr, stmts1, top1) <- exprToVar env addr
    (env2, vval,  stmts2, top2) <- exprToVar env1 val

    let stmts = stmts1 `appOL` stmts2
    case getVarType vaddr of
        -- sometimes we need to cast an int to a pointer before storing
        LMPointer ty@(LMPointer _) | getVarType vval == llvmWord -> do
            (v, s1) <- doExpr ty $ Cast LM_Inttoptr vval ty
            let s2 = Store v vaddr
            return (env2, stmts `snocOL` s1 `snocOL` s2, top1 ++ top2)

        LMPointer _ -> do
            let s1 = Store vval vaddr
            return (env2, stmts `snocOL` s1, top1 ++ top2)

        i@(LMInt _) | i == llvmWord -> do
            let vty = pLift $ getVarType vval
            (vptr, s1) <- doExpr vty $ Cast LM_Inttoptr vaddr vty
            let s2 = Store vval vptr
            return (env2, stmts `snocOL` s1 `snocOL` s2, top1 ++ top2)

        other ->
            pprPanic "genStore: ptr not right type!"
                    (PprCmm.pprExpr (getLlvmPlatform env) addr <+> text (
                        "Size of Ptr: " ++ show llvmPtrBits ++
                        ", Size of var: " ++ show (llvmWidthInBits other) ++
                        ", Var: " ++ show vaddr))


-- | Unconditional branch
genBranch :: LlvmEnv -> BlockId -> UniqSM StmtData
genBranch env id =
    let label = blockIdToLlvm id
    in return (env, unitOL $ Branch label, [])


-- | Conditional branch
genCondBranch :: LlvmEnv -> CmmExpr -> BlockId -> UniqSM StmtData
genCondBranch env cond idT = do
    idF <- getUniqueUs
    let labelT = blockIdToLlvm idT
    let labelF = LMLocalVar idF LMLabel
    (env', vc, stmts, top) <- exprToVarOpt env i1Option cond
    if getVarType vc == i1
        then do
            let s1 = BranchIf vc labelT labelF
            let s2 = MkLabel idF
            return $ (env', stmts `snocOL` s1 `snocOL` s2, top)
        else
            panic $ "genCondBranch: Cond expr not bool! (" ++ show vc ++ ")"


-- | Switch branch
--
-- N.B. We remove Nothing's from the list of branches, as they are 'undefined'.
-- However, they may be defined one day, so we better document this behaviour.
genSwitch :: LlvmEnv -> CmmExpr -> [Maybe BlockId] -> UniqSM StmtData
genSwitch env cond maybe_ids = do
    (env', vc, stmts, top) <- exprToVar env cond
    let ty = getVarType vc

    let pairs = [ (ix, id) | (ix,Just id) <- zip [0..] maybe_ids ]
    let labels = map (\(ix, b) -> (mkIntLit ty ix, blockIdToLlvm b)) pairs
    -- out of range is undefied, so lets just branch to first label
    let (_, defLbl) = head labels

    let s1 = Switch vc defLbl labels
    return $ (env', stmts `snocOL` s1, top)


-- -----------------------------------------------------------------------------
-- * CmmExpr code generation
--

-- | An expression conversion return data:
--   * LlvmEnv: The new enviornment
--   * LlvmVar: The var holding the result of the expression
--   * LlvmStatements: Any statements needed to evaluate the expression
--   * LlvmCmmDecl: Any global data needed for this expression
type ExprData = (LlvmEnv, LlvmVar, LlvmStatements, [LlvmCmmDecl])

-- | Values which can be passed to 'exprToVar' to configure its
-- behaviour in certain circumstances.
data EOption = EOption {
        -- | The expected LlvmType for the returned variable.
        --
        -- Currently just used for determining if a comparison should return
        -- a boolean (i1) or a int (i32/i64).
        eoExpectedType :: Maybe LlvmType
  }

i1Option :: EOption
i1Option = EOption (Just i1)

wordOption :: EOption
wordOption = EOption (Just llvmWord)


-- | Convert a CmmExpr to a list of LlvmStatements with the result of the
-- expression being stored in the returned LlvmVar.
exprToVar :: LlvmEnv -> CmmExpr -> UniqSM ExprData
exprToVar env = exprToVarOpt env wordOption

exprToVarOpt :: LlvmEnv -> EOption -> CmmExpr -> UniqSM ExprData
exprToVarOpt env opt e = case e of

    CmmLit lit
        -> genLit env lit

    CmmLoad e' ty
        -> genLoad env e' ty

    -- Cmmreg in expression is the value, so must load. If you want actual
    -- reg pointer, call getCmmReg directly.
    CmmReg r -> do
        let (env', vreg, stmts, top) = getCmmReg env r
        (v1, s1) <- doExpr (pLower $ getVarType vreg) $ Load vreg
        case (isPointer . getVarType) v1 of
             True  -> do
                 -- Cmm wants the value, so pointer types must be cast to ints
                 (v2, s2) <- doExpr llvmWord $ Cast LM_Ptrtoint v1 llvmWord
                 return (env', v2, stmts `snocOL` s1 `snocOL` s2, top)

             False -> return (env', v1, stmts `snocOL` s1, top)

    CmmMachOp op exprs
        -> genMachOp env opt op exprs

    CmmRegOff r i
        -> exprToVar env $ expandCmmReg (r, i)

    CmmStackSlot _ _
        -> panic "exprToVar: CmmStackSlot not supported!"


-- | Handle CmmMachOp expressions
genMachOp :: LlvmEnv -> EOption -> MachOp -> [CmmExpr] -> UniqSM ExprData

-- Unary Machop
genMachOp env _ op [x] = case op of

    MO_Not w ->
        let all1 = mkIntLit (widthToLlvmInt w) (-1)
        in negate (widthToLlvmInt w) all1 LM_MO_Xor

    MO_S_Neg w ->
        let all0 = mkIntLit (widthToLlvmInt w) 0
        in negate (widthToLlvmInt w) all0 LM_MO_Sub

    MO_F_Neg w ->
        let all0 = LMLitVar $ LMFloatLit (-0) (widthToLlvmFloat w)
        in negate (widthToLlvmFloat w) all0 LM_MO_FSub

    MO_SF_Conv _ w -> fiConv (widthToLlvmFloat w) LM_Sitofp
    MO_FS_Conv _ w -> fiConv (widthToLlvmInt w) LM_Fptosi

    MO_SS_Conv from to
        -> sameConv from (widthToLlvmInt to) LM_Trunc LM_Sext

    MO_UU_Conv from to
        -> sameConv from (widthToLlvmInt to) LM_Trunc LM_Zext

    MO_FF_Conv from to
        -> sameConv from (widthToLlvmFloat to) LM_Fptrunc LM_Fpext

    -- Handle unsupported cases explicitly so we get a warning
    -- of missing case when new MachOps added
    MO_Add _          -> panicOp
    MO_Mul _          -> panicOp
    MO_Sub _          -> panicOp
    MO_S_MulMayOflo _ -> panicOp
    MO_S_Quot _       -> panicOp
    MO_S_Rem _        -> panicOp
    MO_U_MulMayOflo _ -> panicOp
    MO_U_Quot _       -> panicOp
    MO_U_Rem _        -> panicOp

    MO_Eq  _          -> panicOp
    MO_Ne  _          -> panicOp
    MO_S_Ge _         -> panicOp
    MO_S_Gt _         -> panicOp
    MO_S_Le _         -> panicOp
    MO_S_Lt _         -> panicOp
    MO_U_Ge _         -> panicOp
    MO_U_Gt _         -> panicOp
    MO_U_Le _         -> panicOp
    MO_U_Lt _         -> panicOp

    MO_F_Add        _ -> panicOp
    MO_F_Sub        _ -> panicOp
    MO_F_Mul        _ -> panicOp
    MO_F_Quot       _ -> panicOp
    MO_F_Eq         _ -> panicOp
    MO_F_Ne         _ -> panicOp
    MO_F_Ge         _ -> panicOp
    MO_F_Gt         _ -> panicOp
    MO_F_Le         _ -> panicOp
    MO_F_Lt         _ -> panicOp

    MO_And          _ -> panicOp
    MO_Or           _ -> panicOp
    MO_Xor          _ -> panicOp
    MO_Shl          _ -> panicOp
    MO_U_Shr        _ -> panicOp
    MO_S_Shr        _ -> panicOp

    where
        negate ty v2 negOp = do
            (env', vx, stmts, top) <- exprToVar env x
            (v1, s1) <- doExpr ty $ LlvmOp negOp v2 vx
            return (env', v1, stmts `snocOL` s1, top)

        fiConv ty convOp = do
            (env', vx, stmts, top) <- exprToVar env x
            (v1, s1) <- doExpr ty $ Cast convOp vx ty
            return (env', v1, stmts `snocOL` s1, top)

        sameConv from ty reduce expand = do
            x'@(env', vx, stmts, top) <- exprToVar env x
            let sameConv' op = do
                (v1, s1) <- doExpr ty $ Cast op vx ty
                return (env', v1, stmts `snocOL` s1, top)
            let toWidth = llvmWidthInBits ty
            -- LLVM doesn't like trying to convert to same width, so
            -- need to check for that as we do get Cmm code doing it.
            case widthInBits from  of
                 w | w < toWidth -> sameConv' expand
                 w | w > toWidth -> sameConv' reduce
                 _w              -> return x'
        
        panicOp = panic $ "LLVM.CodeGen.genMachOp: non unary op encourntered"
                       ++ "with one argument! (" ++ show op ++ ")"

-- Handle GlobalRegs pointers
genMachOp env opt o@(MO_Add _) e@[(CmmReg (CmmGlobal r)), (CmmLit (CmmInt n _))]
    = genMachOp_fast env opt o r (fromInteger n) e

genMachOp env opt o@(MO_Sub _) e@[(CmmReg (CmmGlobal r)), (CmmLit (CmmInt n _))]
    = genMachOp_fast env opt o r (negate . fromInteger $ n) e

-- Generic case
genMachOp env opt op e = genMachOp_slow env opt op e


-- | Handle CmmMachOp expressions
-- This is a specialised method that handles Global register manipulations like
-- 'Sp - 16', using the getelementptr instruction.
genMachOp_fast :: LlvmEnv -> EOption -> MachOp -> GlobalReg -> Int -> [CmmExpr]
               -> UniqSM ExprData
genMachOp_fast env opt op r n e
  = let gr  = lmGlobalRegVar r
        grt = (pLower . getVarType) gr
        (ix,rem) = n `divMod` ((llvmWidthInBits . pLower) grt  `div` 8)
    in case isPointer grt && rem == 0 of
            True -> do
                (gv,  s1) <- doExpr grt $ Load gr
                (ptr, s2) <- doExpr grt $ GetElemPtr True gv [toI32 ix]
                (var, s3) <- doExpr llvmWord $ Cast LM_Ptrtoint ptr llvmWord
                return (env, var, unitOL s1 `snocOL` s2 `snocOL` s3, [])

            False -> genMachOp_slow env opt op e


-- | Handle CmmMachOp expressions
-- This handles all the cases not handle by the specialised genMachOp_fast.
genMachOp_slow :: LlvmEnv -> EOption -> MachOp -> [CmmExpr] -> UniqSM ExprData

-- Binary MachOp
genMachOp_slow env opt op [x, y] = case op of

    MO_Eq _   -> genBinComp opt LM_CMP_Eq
    MO_Ne _   -> genBinComp opt LM_CMP_Ne

    MO_S_Gt _ -> genBinComp opt LM_CMP_Sgt
    MO_S_Ge _ -> genBinComp opt LM_CMP_Sge
    MO_S_Lt _ -> genBinComp opt LM_CMP_Slt
    MO_S_Le _ -> genBinComp opt LM_CMP_Sle

    MO_U_Gt _ -> genBinComp opt LM_CMP_Ugt
    MO_U_Ge _ -> genBinComp opt LM_CMP_Uge
    MO_U_Lt _ -> genBinComp opt LM_CMP_Ult
    MO_U_Le _ -> genBinComp opt LM_CMP_Ule

    MO_Add _ -> genBinMach LM_MO_Add
    MO_Sub _ -> genBinMach LM_MO_Sub
    MO_Mul _ -> genBinMach LM_MO_Mul

    MO_U_MulMayOflo _ -> panic "genMachOp: MO_U_MulMayOflo unsupported!"

    MO_S_MulMayOflo w -> isSMulOK w x y

    MO_S_Quot _ -> genBinMach LM_MO_SDiv
    MO_S_Rem  _ -> genBinMach LM_MO_SRem

    MO_U_Quot _ -> genBinMach LM_MO_UDiv
    MO_U_Rem  _ -> genBinMach LM_MO_URem

    MO_F_Eq _ -> genBinComp opt LM_CMP_Feq
    MO_F_Ne _ -> genBinComp opt LM_CMP_Fne
    MO_F_Gt _ -> genBinComp opt LM_CMP_Fgt
    MO_F_Ge _ -> genBinComp opt LM_CMP_Fge
    MO_F_Lt _ -> genBinComp opt LM_CMP_Flt
    MO_F_Le _ -> genBinComp opt LM_CMP_Fle

    MO_F_Add  _ -> genBinMach LM_MO_FAdd
    MO_F_Sub  _ -> genBinMach LM_MO_FSub
    MO_F_Mul  _ -> genBinMach LM_MO_FMul
    MO_F_Quot _ -> genBinMach LM_MO_FDiv

    MO_And _   -> genBinMach LM_MO_And
    MO_Or  _   -> genBinMach LM_MO_Or
    MO_Xor _   -> genBinMach LM_MO_Xor
    MO_Shl _   -> genBinMach LM_MO_Shl
    MO_U_Shr _ -> genBinMach LM_MO_LShr
    MO_S_Shr _ -> genBinMach LM_MO_AShr

    MO_Not _       -> panicOp
    MO_S_Neg _     -> panicOp
    MO_F_Neg _     -> panicOp

    MO_SF_Conv _ _ -> panicOp
    MO_FS_Conv _ _ -> panicOp
    MO_SS_Conv _ _ -> panicOp
    MO_UU_Conv _ _ -> panicOp
    MO_FF_Conv _ _ -> panicOp

    where
        binLlvmOp ty binOp = do
            (env1, vx, stmts1, top1) <- exprToVar env x
            (env2, vy, stmts2, top2) <- exprToVar env1 y
            if getVarType vx == getVarType vy
                then do
                    (v1, s1) <- doExpr (ty vx) $ binOp vx vy
                    return (env2, v1, stmts1 `appOL` stmts2 `snocOL` s1,
                            top1 ++ top2)

                else do
                    -- Error. Continue anyway so we can debug the generated ll file.
                    let cmmToStr = (lines . show . llvmSDoc . PprCmm.pprExpr (getLlvmPlatform env))
                    let dx = Comment $ map fsLit $ cmmToStr x
                    let dy = Comment $ map fsLit $ cmmToStr y
                    (v1, s1) <- doExpr (ty vx) $ binOp vx vy
                    let allStmts = stmts1 `appOL` stmts2 `snocOL` dx
                                    `snocOL` dy `snocOL` s1
                    return (env2, v1, allStmts, top1 ++ top2)

        -- | Need to use EOption here as Cmm expects word size results from
        -- comparisons while LLVM return i1. Need to extend to llvmWord type
        -- if expected
        genBinComp opt cmp = do
            ed@(env', v1, stmts, top) <- binLlvmOp (\_ -> i1) $ Compare cmp

            if getVarType v1 == i1
                then
                    case eoExpectedType opt of
                         Nothing ->
                             return ed

                         Just t | t == i1 ->
                                    return ed

                                | isInt t -> do
                                    (v2, s1) <- doExpr t $ Cast LM_Zext v1 t
                                    return (env', v2, stmts `snocOL` s1, top)

                                | otherwise ->
                                    panic $ "genBinComp: Can't case i1 compare"
                                        ++ "res to non int type " ++ show (t)
                else
                    panic $ "genBinComp: Compare returned type other then i1! "
                        ++ (show $ getVarType v1)

        genBinMach op = binLlvmOp getVarType (LlvmOp op)

        -- | Detect if overflow will occur in signed multiply of the two
        -- CmmExpr's. This is the LLVM assembly equivalent of the NCG
        -- implementation. Its much longer due to type information/safety.
        -- This should actually compile to only about 3 asm instructions.
        isSMulOK :: Width -> CmmExpr -> CmmExpr -> UniqSM ExprData
        isSMulOK _ x y = do
            (env1, vx, stmts1, top1) <- exprToVar env x
            (env2, vy, stmts2, top2) <- exprToVar env1 y

            let word  = getVarType vx
            let word2 = LMInt $ 2 * (llvmWidthInBits $ getVarType vx)
            let shift = llvmWidthInBits word
            let shift1 = toIWord (shift - 1)
            let shift2 = toIWord shift

            if isInt word
                then do
                    (x1, s1)     <- doExpr word2 $ Cast LM_Sext vx word2
                    (y1, s2)     <- doExpr word2 $ Cast LM_Sext vy word2
                    (r1, s3)     <- doExpr word2 $ LlvmOp LM_MO_Mul x1 y1
                    (rlow1, s4)  <- doExpr word $ Cast LM_Trunc r1 word
                    (rlow2, s5)  <- doExpr word $ LlvmOp LM_MO_AShr rlow1 shift1
                    (rhigh1, s6) <- doExpr word2 $ LlvmOp LM_MO_AShr r1 shift2
                    (rhigh2, s7) <- doExpr word $ Cast LM_Trunc rhigh1 word
                    (dst, s8)    <- doExpr word $ LlvmOp LM_MO_Sub rlow2 rhigh2
                    let stmts = (unitOL s1) `snocOL` s2 `snocOL` s3 `snocOL` s4
                            `snocOL` s5 `snocOL` s6 `snocOL` s7 `snocOL` s8
                    return (env2, dst, stmts1 `appOL` stmts2 `appOL` stmts,
                        top1 ++ top2)

                else
                    panic $ "isSMulOK: Not bit type! (" ++ show word ++ ")"

        panicOp = panic $ "LLVM.CodeGen.genMachOp_slow: unary op encourntered"
                       ++ "with two arguments! (" ++ show op ++ ")"

-- More then two expression, invalid!
genMachOp_slow _ _ _ _ = panic "genMachOp: More then 2 expressions in MachOp!"


-- | Handle CmmLoad expression.
genLoad :: LlvmEnv -> CmmExpr -> CmmType -> UniqSM ExprData

-- First we try to detect a few common cases and produce better code for
-- these then the default case. We are mostly trying to detect Cmm code
-- like I32[Sp + n] and use 'getelementptr' operations instead of the
-- generic case that uses casts and pointer arithmetic
genLoad env e@(CmmReg (CmmGlobal r)) ty
    = genLoad_fast env e r 0 ty

genLoad env e@(CmmRegOff (CmmGlobal r) n) ty
    = genLoad_fast env e r n ty

genLoad env e@(CmmMachOp (MO_Add _) [
                            (CmmReg (CmmGlobal r)),
                            (CmmLit (CmmInt n _))])
                ty
    = genLoad_fast env e r (fromInteger n) ty

genLoad env e@(CmmMachOp (MO_Sub _) [
                            (CmmReg (CmmGlobal r)),
                            (CmmLit (CmmInt n _))])
                ty
    = genLoad_fast env e r (negate $ fromInteger n) ty

-- generic case
genLoad env e ty = genLoad_slow env e ty

-- | Handle CmmLoad expression.
-- This is a special case for loading from a global register pointer
-- offset such as I32[Sp+8].
genLoad_fast :: LlvmEnv -> CmmExpr -> GlobalReg -> Int -> CmmType
                -> UniqSM ExprData
genLoad_fast env e r n ty =
    let gr  = lmGlobalRegVar r
        grt = (pLower . getVarType) gr
        ty' = cmmToLlvmType ty
        (ix,rem) = n `divMod` ((llvmWidthInBits . pLower) grt  `div` 8)
    in case isPointer grt && rem == 0 of
            True  -> do
                (gv,  s1) <- doExpr grt $ Load gr
                (ptr, s2) <- doExpr grt $ GetElemPtr True gv [toI32 ix]
                -- We might need a different pointer type, so check
                case grt == ty' of
                     -- were fine
                     True -> do
                         (var, s3) <- doExpr ty' $ Load ptr
                         return (env, var, unitOL s1 `snocOL` s2 `snocOL` s3,
                                     [])

                     -- cast to pointer type needed
                     False -> do
                         let pty = pLift ty'
                         (ptr', s3) <- doExpr pty $ Cast LM_Bitcast ptr pty
                         (var, s4) <- doExpr ty' $ Load ptr'
                         return (env, var, unitOL s1 `snocOL` s2 `snocOL` s3
                                    `snocOL` s4, [])

            -- If its a bit type then we use the slow method since
            -- we can't avoid casting anyway.
            False -> genLoad_slow env e ty


-- | Handle Cmm load expression.
-- Generic case. Uses casts and pointer arithmetic if needed.
genLoad_slow :: LlvmEnv -> CmmExpr -> CmmType -> UniqSM ExprData
genLoad_slow env e ty = do
    (env', iptr, stmts, tops) <- exprToVar env e
    case getVarType iptr of
         LMPointer _ -> do
                    (dvar, load) <- doExpr (cmmToLlvmType ty) $ Load iptr
                    return (env', dvar, stmts `snocOL` load, tops)

         i@(LMInt _) | i == llvmWord -> do
                    let pty = LMPointer $ cmmToLlvmType ty
                    (ptr, cast)  <- doExpr pty $ Cast LM_Inttoptr iptr pty
                    (dvar, load) <- doExpr (cmmToLlvmType ty) $ Load ptr
                    return (env', dvar, stmts `snocOL` cast `snocOL` load, tops)

         other -> pprPanic "exprToVar: CmmLoad expression is not right type!"
                        (PprCmm.pprExpr (getLlvmPlatform env) e <+> text (
                            "Size of Ptr: " ++ show llvmPtrBits ++
                            ", Size of var: " ++ show (llvmWidthInBits other) ++
                            ", Var: " ++ show iptr))


-- | Handle CmmReg expression
--
-- We allocate CmmReg on the stack. This avoids having to map a CmmReg to an
-- equivalent SSA form and avoids having to deal with Phi node insertion.
-- This is also the approach recommended by LLVM developers.
getCmmReg :: LlvmEnv -> CmmReg -> ExprData
getCmmReg env r@(CmmLocal (LocalReg un _))
  = let exists = varLookup un env

        (newv, stmts) = allocReg r
        nenv = varInsert un (pLower $ getVarType newv) env
    in case exists of
            Just ety -> (env, (LMLocalVar un $ pLift ety), nilOL, [])
            Nothing  -> (nenv, newv, stmts, [])

getCmmReg env (CmmGlobal g) = (env, lmGlobalRegVar g, nilOL, [])


-- | Allocate a CmmReg on the stack
allocReg :: CmmReg -> (LlvmVar, LlvmStatements)
allocReg (CmmLocal (LocalReg un ty))
  = let ty' = cmmToLlvmType ty
        var = LMLocalVar un (LMPointer ty')
        alc = Alloca ty' 1
    in (var, unitOL $ Assignment var alc)

allocReg _ = panic $ "allocReg: Global reg encountered! Global registers should"
                    ++ " have been handled elsewhere!"


-- | Generate code for a literal
genLit :: LlvmEnv -> CmmLit -> UniqSM ExprData
genLit env (CmmInt i w)
  = return (env, mkIntLit (LMInt $ widthInBits w) i, nilOL, [])

genLit env (CmmFloat r w)
  = return (env, LMLitVar $ LMFloatLit (fromRational r) (widthToLlvmFloat w),
              nilOL, [])

genLit env cmm@(CmmLabel l)
  = let label = strCLabel_llvm env l
        ty = funLookup label env
        lmty = cmmToLlvmType $ cmmLitType cmm
    in case ty of
            -- Make generic external label definition and then pointer to it
            Nothing -> do
                let glob@(var, _) = genStringLabelRef label
                let ldata = [CmmData Data [([glob], [])]]
                let env' = funInsert label (pLower $ getVarType var) env
                (v1, s1) <- doExpr lmty $ Cast LM_Ptrtoint var llvmWord
                return (env', v1, unitOL s1, ldata)

            -- Referenced data exists in this module, retrieve type and make
            -- pointer to it.
            Just ty' -> do
                let var = LMGlobalVar label (LMPointer ty')
                            ExternallyVisible Nothing Nothing False
                (v1, s1) <- doExpr lmty $ Cast LM_Ptrtoint var llvmWord
                return (env, v1, unitOL s1, [])

genLit env (CmmLabelOff label off) = do
    (env', vlbl, stmts, stat) <- genLit env (CmmLabel label)
    let voff = toIWord off
    (v1, s1) <- doExpr (getVarType vlbl) $ LlvmOp LM_MO_Add vlbl voff
    return (env', v1, stmts `snocOL` s1, stat)

genLit env (CmmLabelDiffOff l1 l2 off) = do
    (env1, vl1, stmts1, stat1) <- genLit env (CmmLabel l1)
    (env2, vl2, stmts2, stat2) <- genLit env1 (CmmLabel l2)
    let voff = toIWord off
    let ty1 = getVarType vl1
    let ty2 = getVarType vl2
    if (isInt ty1) && (isInt ty2)
       && (llvmWidthInBits ty1 == llvmWidthInBits ty2)

       then do
            (v1, s1) <- doExpr (getVarType vl1) $ LlvmOp LM_MO_Sub vl1 vl2
            (v2, s2) <- doExpr (getVarType v1 ) $ LlvmOp LM_MO_Add v1 voff
            return (env2, v2, stmts1 `appOL` stmts2 `snocOL` s1 `snocOL` s2,
                        stat1 ++ stat2)

        else
            panic "genLit: CmmLabelDiffOff encountered with different label ty!"

genLit env (CmmBlock b)
  = genLit env (CmmLabel $ infoTblLbl b)

genLit _ CmmHighStackMark
  = panic "genStaticLit - CmmHighStackMark unsupported!"


-- -----------------------------------------------------------------------------
-- * Misc
--

-- | Function prologue. Load STG arguments into variables for function.
funPrologue :: [LlvmStatement]
funPrologue = concat $ map getReg activeStgRegs
    where getReg rr =
            let reg   = lmGlobalRegVar rr
                arg   = lmGlobalRegArg rr
                alloc = Assignment reg $ Alloca (pLower $ getVarType reg) 1
            in [alloc, Store arg reg]


-- | Function epilogue. Load STG variables to use as argument for call.
funEpilogue :: UniqSM ([LlvmVar], LlvmStatements)
funEpilogue = do
    let loadExpr r = do
        let reg = lmGlobalRegVar r
        (v,s) <- doExpr (pLower $ getVarType reg) $ Load reg
        return (v, unitOL s)
    loads <- mapM loadExpr activeStgRegs
    let (vars, stmts) = unzip loads
    return (vars, concatOL stmts)


-- | A serries of statements to trash all the STG registers.
--
-- In LLVM we pass the STG registers around everywhere in function calls.
-- So this means LLVM considers them live across the entire function, when
-- in reality they usually aren't. For Caller save registers across C calls
-- the saving and restoring of them is done by the Cmm code generator,
-- using Cmm local vars. So to stop LLVM saving them as well (and saving
-- all of them since it thinks they're always live, we trash them just
-- before the call by assigning the 'undef' value to them. The ones we
-- need are restored from the Cmm local var and the ones we don't need
-- are fine to be trashed.
trashStmts :: LlvmStatements
trashStmts = concatOL $ map trashReg activeStgRegs
    where trashReg r =
            let reg   = lmGlobalRegVar r
                ty    = (pLower . getVarType) reg
                trash = unitOL $ Store (LMLitVar $ LMUndefLit ty) reg
            in case callerSaves r of
                      True  -> trash
                      False -> nilOL


-- | Get a function pointer to the CLabel specified.
--
-- This is for Haskell functions, function type is assumed, so doesn't work
-- with foreign functions.
getHsFunc :: LlvmEnv -> CLabel -> UniqSM ExprData
getHsFunc env lbl
  = let fn = strCLabel_llvm env lbl
        ty    = funLookup fn env
    in case ty of
        -- Function in module in right form
        Just ty'@(LMFunction sig) -> do
            let fun = LMGlobalVar fn ty' (funcLinkage sig) Nothing Nothing False
            return (env, fun, nilOL, [])

        -- label in module but not function pointer, convert
        Just ty' -> do
            let fun = LMGlobalVar fn (pLift ty') ExternallyVisible
                            Nothing Nothing False
            (v1, s1) <- doExpr (pLift llvmFunTy) $
                            Cast LM_Bitcast fun (pLift llvmFunTy)
            return (env, v1, unitOL s1, [])

        -- label not in module, create external reference
        Nothing  -> do
            let ty' = LMFunction $ llvmFunSig env lbl ExternallyVisible
            let fun = LMGlobalVar fn ty' ExternallyVisible Nothing Nothing False
            let top = CmmData Data [([],[ty'])]
            let env' = funInsert fn ty' env
            return (env', fun, nilOL, [top])


-- | Create a new local var
mkLocalVar :: LlvmType -> UniqSM LlvmVar
mkLocalVar ty = do
    un <- getUniqueUs
    return $ LMLocalVar un ty


-- | Execute an expression, assigning result to a var
doExpr :: LlvmType -> LlvmExpression -> UniqSM (LlvmVar, LlvmStatement)
doExpr ty expr = do
    v <- mkLocalVar ty
    return (v, Assignment v expr)


-- | Expand CmmRegOff
expandCmmReg :: (CmmReg, Int) -> CmmExpr
expandCmmReg (reg, off)
  = let width = typeWidth (cmmRegType reg)
        voff  = CmmLit $ CmmInt (fromIntegral off) width
    in CmmMachOp (MO_Add width) [CmmReg reg, voff]


-- | Convert a block id into a appropriate Llvm label
blockIdToLlvm :: BlockId -> LlvmVar
blockIdToLlvm bid = LMLocalVar (getUnique bid) LMLabel

-- | Create Llvm int Literal
mkIntLit :: Integral a => LlvmType -> a -> LlvmVar
mkIntLit ty i = LMLitVar $ LMIntLit (toInteger i) ty

-- | Convert int type to a LLvmVar of word or i32 size
toI32, toIWord :: Integral a => a -> LlvmVar
toI32 = mkIntLit i32
toIWord = mkIntLit llvmWord


-- | Error functions
panic :: String -> a
panic s = Outputable.panic $ "LlvmCodeGen.CodeGen." ++ s

pprPanic :: String -> SDoc -> a
pprPanic s d = Outputable.pprPanic ("LlvmCodeGen.CodeGen." ++ s) d

