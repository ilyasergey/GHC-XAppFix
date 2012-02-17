%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}

-- | Abstract Haskell syntax for expressions.
module HsExpr where

#include "HsVersions.h"

-- friends:
import HsDecls
import HsPat
import HsLit
import HsTypes
import HsBinds

-- others:
import TcEvidence
import CoreSyn
import Var
import Name
import BasicTypes
import DataCon
import SrcLoc
import Util( dropTail )
import StaticFlags( opt_PprStyle_Debug )
import Outputable
import FastString
import Unique
import UniqFM

-- libraries:
import Data.Data hiding (Fixity)
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Expressions proper}
%*                                                                      *
%************************************************************************

\begin{code}
-- * Expressions proper

type LHsExpr id = Located (HsExpr id)

-------------------------
-- | PostTcExpr is an evidence expression attached to the syntax tree by the
-- type checker (c.f. postTcType).
type PostTcExpr  = HsExpr Id
-- | We use a PostTcTable where there are a bunch of pieces of evidence, more
-- than is convenient to keep individually.
type PostTcTable = [(Name, PostTcExpr)]

noPostTcExpr :: PostTcExpr
noPostTcExpr = HsLit (HsString (fsLit "noPostTcExpr"))

noPostTcTable :: PostTcTable
noPostTcTable = []

-------------------------
-- | SyntaxExpr is like 'PostTcExpr', but it's filled in a little earlier,
-- by the renamer.  It's used for rebindable syntax.
--
-- E.g. @(>>=)@ is filled in before the renamer by the appropriate 'Name' for
--      @(>>=)@, and then instantiated by the type checker with its type args
--      etc

type SyntaxExpr id = HsExpr id

noSyntaxExpr :: SyntaxExpr id -- Before renaming, and sometimes after,
                              -- (if the syntax slot makes no sense)
noSyntaxExpr = HsLit (HsString (fsLit "noSyntaxExpr"))


type SyntaxTable id = [(Name, SyntaxExpr id)]
-- ^ Currently used only for 'CmdTop' (sigh)
--
-- * Before the renamer, this list is 'noSyntaxTable'
--
-- * After the renamer, it takes the form @[(std_name, HsVar actual_name)]@
--   For example, for the 'return' op of a monad
--
--    * normal case:            @(GHC.Base.return, HsVar GHC.Base.return)@
--
--    * with rebindable syntax: @(GHC.Base.return, return_22)@
--              where @return_22@ is whatever @return@ is in scope
--
-- * After the type checker, it takes the form @[(std_name, <expression>)]@
--      where @<expression>@ is the evidence for the method

noSyntaxTable :: SyntaxTable id
noSyntaxTable = []

data AletTooling idR = MkAletTooling {
    atAppfixClass :: SyntaxExpr idR
  , atComposeTyCon :: SyntaxExpr idR
  , atTConsTyCon :: SyntaxExpr idR
  , atTNilTyCon :: SyntaxExpr idR
  , atTProdTyCon :: SyntaxExpr idR
  , atPhantomTyCon :: SyntaxExpr idR
  , atPhantom1TyCon :: SyntaxExpr idR
  , atListUTyCon :: SyntaxExpr idR
  , atWrapTArrDTyCon :: SyntaxExpr idR
  , atTElemTyCon :: SyntaxExpr idR
  , atWhoo :: SyntaxExpr idR
  , atWhoo1 :: SyntaxExpr idR
  , atTCons :: SyntaxExpr idR
  , atTNil :: SyntaxExpr idR
  , atWrap :: SyntaxExpr idR
  , atTHere :: SyntaxExpr idR
  , atTThere :: SyntaxExpr idR
  , atProjTProd :: SyntaxExpr idR
  , atNafix2 :: SyntaxExpr idR
  } deriving (Data, Typeable)

noAletTooling :: AletTooling id
noAletTooling = MkAletTooling noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr noSyntaxExpr 

-- a map of the names of binders inside the alet to the corresponding names
-- which are in scope in the "in"-branch
type AletIdentMap id = UniqFM id
aletMapId :: Uniquable id => AletIdentMap id -> id -> Maybe id
aletMapId = lookupUFM

aletMapValues :: Uniquable id => AletIdentMap id -> [id]
aletMapValues = eltsUFM

aletMapEmpty :: AletIdentMap id
aletMapEmpty = emptyUFM

aletEvVarInitial :: EvVar
aletEvVarInitial = panic "appfix: Alet evidence variable is used before computed"

aletHsWrapperInitial :: HsWrapper
aletHsWrapperInitial = panic "HsAletWrapper hasn't yet been summoned"


-------------------------
-- | A Haskell expression.
data HsExpr id
  = HsVar     id                        -- ^ variable
  | HsIPVar   (IPName id)               -- ^ implicit parameter
  | HsOverLit (HsOverLit id)            -- ^ Overloaded literals

  | HsLit     HsLit                     -- ^ Simple (non-overloaded) literals

  | HsLam     (MatchGroup id)           -- Currently always a single match

  | HsApp     (LHsExpr id) (LHsExpr id) -- Application

  -- Operator applications:
  -- NB Bracketed ops such as (+) come out as Vars.

  -- NB We need an expr for the operator in an OpApp/Section since
  -- the typechecker may need to apply the operator to a few types.

  | OpApp       (LHsExpr id)    -- left operand
                (LHsExpr id)    -- operator
                Fixity          -- Renamer adds fixity; bottom until then
                (LHsExpr id)    -- right operand

  | NegApp      (LHsExpr id)    -- negated expr
                (SyntaxExpr id) -- Name of 'negate'

  | HsPar       (LHsExpr id)    -- Parenthesised expr; see Note [Parens in HsSyn]

  | SectionL    (LHsExpr id)    -- operand; see Note [Sections in HsSyn]
                (LHsExpr id)    -- operator
  | SectionR    (LHsExpr id)    -- operator; see Note [Sections in HsSyn]
                (LHsExpr id)    -- operand

  | ExplicitTuple		-- Used for explicit tuples and sections thereof
        [HsTupArg id] 
        Boxity

  | HsCase      (LHsExpr id)
                (MatchGroup id)

  | HsIf        (Maybe (SyntaxExpr id)) -- cond function
    		       		        -- Nothing => use the built-in 'if'
					-- See Note [Rebindable if]
                (LHsExpr id)    --  predicate
                (LHsExpr id)    --  then part
                (LHsExpr id)    --  else part

  | HsLet       (HsLocalBinds id) -- let(rec)
                (LHsExpr  id)

  | HsAlet                        -- alet (ApplicativeFix)
                (HsLocalBinds id) -- bindings
                (LHsExpr  id)     -- body
                EvVar             -- after type checking: 
                                  -- the evidence variable representing the
                                  -- "Applicative f" dictionary
                HsWrapper         -- after type checking: the wrapper that corresponds to
                                  -- the binding of the implicit "forall b. Applicative b"
                                  -- constraint in effect in all of the bindings
                (AletIdentMap id) -- map from variables bound in the bindings to
                                  -- corresponding (separate) variables used in the body
                (AletTooling id)  -- a record containing the stuff we need in the
                                  -- alet transformation. Filled in by the
                                  -- renamer

  | HsDo        (HsStmtContext Name) -- The parameterisation is unimportant
                                     -- because in this context we never use
                                     -- the PatGuard or ParStmt variant
                [LStmt id]           -- "do":one or more stmts
                PostTcType           -- Type of the whole expression

  | ExplicitList                -- syntactic list
                PostTcType      -- Gives type of components of list
                [LHsExpr id]

  | ExplicitPArr                -- syntactic parallel array: [:e1, ..., en:]
                PostTcType      -- type of elements of the parallel array
                [LHsExpr id]

  -- Record construction
  | RecordCon   (Located id)       -- The constructor.  After type checking
                                   -- it's the dataConWrapId of the constructor
                PostTcExpr         -- Data con Id applied to type args
                (HsRecordBinds id)

  -- Record update
  | RecordUpd   (LHsExpr id)
                (HsRecordBinds id)
--		(HsMatchGroup Id)  -- Filled in by the type checker to be 
--				   -- a match that does the job
                [DataCon]          -- Filled in by the type checker to the
                                   -- _non-empty_ list of DataCons that have
                                   -- all the upd'd fields
                [PostTcType]       -- Argument types of *input* record type
                [PostTcType]       --              and  *output* record type
  -- For a type family, the arg types are of the *instance* tycon,
  -- not the family tycon

  | ExprWithTySig                       -- e :: type
                (LHsExpr id)
                (LHsType id)

  | ExprWithTySigOut                    -- TRANSLATION
                (LHsExpr id)
                (LHsType Name)          -- Retain the signature for
                                        -- round-tripping purposes

  | ArithSeq                            -- arithmetic sequence
                PostTcExpr
                (ArithSeqInfo id)

  | PArrSeq                             -- arith. sequence for parallel array
                PostTcExpr              -- [:e1..e2:] or [:e1, e2..e3:]
                (ArithSeqInfo id)

  | HsSCC       FastString              -- "set cost centre" SCC pragma
                (LHsExpr id)            -- expr whose cost is to be measured

  | HsCoreAnn   FastString              -- hdaume: core annotation
                (LHsExpr id)

  -----------------------------------------------------------
  -- MetaHaskell Extensions

  | HsBracket    (HsBracket id)

  | HsBracketOut (HsBracket Name)       -- Output of the type checker is
                                        -- the *original*
                 [PendingSplice]        -- renamed expression, plus
                                        -- _typechecked_ splices to be
                                        -- pasted back in by the desugarer

  | HsSpliceE (HsSplice id)

  | HsQuasiQuoteE (HsQuasiQuote id)
	-- See Note [Quasi-quote overview] in TcSplice

  -----------------------------------------------------------
  -- Arrow notation extension

  | HsProc      (LPat id)               -- arrow abstraction, proc
                (LHsCmdTop id)          -- body of the abstraction
                                        -- always has an empty stack

  ---------------------------------------
  -- The following are commands, not expressions proper

  | HsArrApp            -- Arrow tail, or arrow application (f -< arg)
        (LHsExpr id)    -- arrow expression, f
        (LHsExpr id)    -- input expression, arg
        PostTcType      -- type of the arrow expressions f,
                        -- of the form a t t', where arg :: t
        HsArrAppType    -- higher-order (-<<) or first-order (-<)
        Bool            -- True => right-to-left (f -< arg)
                        -- False => left-to-right (arg >- f)

  | HsArrForm           -- Command formation,  (| e cmd1 .. cmdn |)
        (LHsExpr id)    -- the operator
                        -- after type-checking, a type abstraction to be
                        -- applied to the type of the local environment tuple
        (Maybe Fixity)  -- fixity (filled in by the renamer), for forms that
                        -- were converted from OpApp's by the renamer
        [LHsCmdTop id]  -- argument commands


  ---------------------------------------
  -- Haskell program coverage (Hpc) Support

  | HsTick
     (Tickish id)
     (LHsExpr id)                       -- sub-expression

  | HsBinTick
     Int                                -- module-local tick number for True
     Int                                -- module-local tick number for False
     (LHsExpr id)                       -- sub-expression

  | HsTickPragma                        -- A pragma introduced tick
     (FastString,(Int,Int),(Int,Int))   -- external span for this tick
     (LHsExpr id)

  ---------------------------------------
  -- These constructors only appear temporarily in the parser.
  -- The renamer translates them into the Right Thing.

  | EWildPat                 -- wildcard

  | EAsPat      (Located id) -- as pattern
                (LHsExpr id)

  | EViewPat    (LHsExpr id) -- view pattern
                (LHsExpr id)

  | ELazyPat    (LHsExpr id) -- ~ pattern

  | HsType      (LHsType id) -- Explicit type argument; e.g  f {| Int |} x y

  ---------------------------------------
  -- Finally, HsWrap appears only in typechecker output

  |  HsWrap     HsWrapper    -- TRANSLATION
                (HsExpr id)
  deriving (Data, Typeable)

-- HsTupArg is used for tuple sections
--  (,a,) is represented by  ExplicitTuple [Mising ty1, Present a, Missing ty3]
--  Which in turn stands for (\x:ty1 \y:ty2. (x,a,y))
data HsTupArg id
  = Present (LHsExpr id)	-- The argument
  | Missing PostTcType		-- The argument is missing, but this is its type
  deriving (Data, Typeable)

tupArgPresent :: HsTupArg id -> Bool
tupArgPresent (Present {}) = True
tupArgPresent (Missing {}) = False

type PendingSplice = (Name, LHsExpr Id) -- Typechecked splices, waiting to be
                                        -- pasted back in by the desugarer

\end{code}

Note [Parens in HsSyn]
~~~~~~~~~~~~~~~~~~~~~~
HsPar (and ParPat in patterns, HsParTy in types) is used as follows

  * Generally HsPar is optional; the pretty printer adds parens where
    necessary.  Eg (HsApp f (HsApp g x)) is fine, and prints 'f (g x)'

  * HsPars are pretty printed as '( .. )' regardless of whether 
    or not they are strictly necssary

  * HsPars are respected when rearranging operator fixities.
    So   a * (b + c)  means what it says (where the parens are an HsPar)

Note [Sections in HsSyn]
~~~~~~~~~~~~~~~~~~~~~~~~
Sections should always appear wrapped in an HsPar, thus
	 HsPar (SectionR ...)
The parser parses sections in a wider variety of situations 
(See Note [Parsing sections]), but the renamer checks for those
parens.  This invariant makes pretty-printing easier; we don't need 
a special case for adding the parens round sections.

Note [Rebindable if]
~~~~~~~~~~~~~~~~~~~~
The rebindable syntax for 'if' is a bit special, because when
rebindable syntax is *off* we do not want to treat
   (if c then t else e)
as if it was an application (ifThenElse c t e).  Why not?
Because we allow an 'if' to return *unboxed* results, thus 
  if blah then 3# else 4#
whereas that would not be possible using a all to a polymorphic function
(because you can't call a polymorphic function at an unboxed type).

So we use Nothing to mean "use the old built-in typing rule".

\begin{code}
instance OutputableBndr id => Outputable (HsExpr id) where
    ppr expr = pprExpr expr
\end{code}

\begin{code}
-----------------------
-- pprExpr, pprLExpr, pprBinds call pprDeeper;
-- the underscore versions do not
pprLExpr :: OutputableBndr id => LHsExpr id -> SDoc
pprLExpr (L _ e) = pprExpr e

pprExpr :: OutputableBndr id => HsExpr id -> SDoc
pprExpr e | isAtomicHsExpr e || isQuietHsExpr e =            ppr_expr e
          | otherwise                           = pprDeeper (ppr_expr e)

isQuietHsExpr :: HsExpr id -> Bool
-- Parentheses do display something, but it gives little info and
-- if we go deeper when we go inside them then we get ugly things
-- like (...)
isQuietHsExpr (HsPar _) = True
-- applications don't display anything themselves
isQuietHsExpr (HsApp _ _) = True
isQuietHsExpr (OpApp _ _ _ _) = True
isQuietHsExpr _ = False

pprBinds :: (OutputableBndr idL, OutputableBndr idR)
         => HsLocalBindsLR idL idR -> SDoc
pprBinds b = pprDeeper (ppr b)

-----------------------
ppr_lexpr :: OutputableBndr id => LHsExpr id -> SDoc
ppr_lexpr e = ppr_expr (unLoc e)

ppr_expr :: forall id. OutputableBndr id => HsExpr id -> SDoc
ppr_expr (HsVar v)       = pprPrefixOcc v
ppr_expr (HsIPVar v)     = ppr v
ppr_expr (HsLit lit)     = ppr lit
ppr_expr (HsOverLit lit) = ppr lit
ppr_expr (HsPar e)       = parens (ppr_lexpr e)

ppr_expr (HsCoreAnn s e)
  = vcat [ptext (sLit "HsCoreAnn") <+> ftext s, ppr_lexpr e]

ppr_expr (HsApp e1 e2)
  = let (fun, args) = collect_args e1 [e2] in
    hang (ppr_lexpr fun) 2 (sep (map pprParendExpr args))
  where
    collect_args (L _ (HsApp fun arg)) args = collect_args fun (arg:args)
    collect_args fun args = (fun, args)

ppr_expr (OpApp e1 op _ e2)
  = case unLoc op of
      HsVar v -> pp_infixly v
      _       -> pp_prefixly
  where
    pp_e1 = pprDebugParendExpr e1   -- In debug mode, add parens
    pp_e2 = pprDebugParendExpr e2   -- to make precedence clear

    pp_prefixly
      = hang (ppr op) 2 (sep [pp_e1, pp_e2])

    pp_infixly v
      = sep [pp_e1, sep [pprInfixOcc v, nest 2 pp_e2]]

ppr_expr (NegApp e _) = char '-' <+> pprDebugParendExpr e

ppr_expr (SectionL expr op)
  = case unLoc op of
      HsVar v -> pp_infixly v
      _       -> pp_prefixly
  where
    pp_expr = pprDebugParendExpr expr

    pp_prefixly = hang (hsep [text " \\ x_ ->", ppr op])
                       4 (hsep [pp_expr, ptext (sLit "x_ )")])
    pp_infixly v = (sep [pp_expr, pprInfixOcc v])

ppr_expr (SectionR op expr)
  = case unLoc op of
      HsVar v -> pp_infixly v
      _       -> pp_prefixly
  where
    pp_expr = pprDebugParendExpr expr

    pp_prefixly = hang (hsep [text "( \\ x_ ->", ppr op, ptext (sLit "x_")])
                       4 ((<>) pp_expr rparen)
    pp_infixly v = sep [pprInfixOcc v, pp_expr]

ppr_expr (ExplicitTuple exprs boxity)
  = tupleParens (boxityNormalTupleSort boxity) (fcat (ppr_tup_args exprs))
  where
    ppr_tup_args []               = []
    ppr_tup_args (Present e : es) = (ppr_lexpr e <> punc es) : ppr_tup_args es
    ppr_tup_args (Missing _ : es) = punc es : ppr_tup_args es

    punc (Present {} : _) = comma <> space
    punc (Missing {} : _) = comma
    punc []               = empty

--avoid using PatternSignatures for stage1 code portability
ppr_expr (HsLam matches)
  = pprMatches (LambdaExpr :: HsMatchContext id) matches

ppr_expr (HsCase expr matches)
  = sep [ sep [ptext (sLit "case"), nest 4 (ppr expr), ptext (sLit "of {")],
          nest 2 (pprMatches (CaseAlt :: HsMatchContext id) matches <+> char '}') ]

ppr_expr (HsIf _ e1 e2 e3)
  = sep [hsep [ptext (sLit "if"), nest 2 (ppr e1), ptext (sLit "then")],
         nest 4 (ppr e2),
         ptext (sLit "else"),
         nest 4 (ppr e3)]

-- special case: let ... in let ...
ppr_expr (HsLet binds expr@(L _ (HsLet _ _)))
  = sep [hang (ptext (sLit "let")) 2 (hsep [pprBinds binds, ptext (sLit "in")]),
         ppr_lexpr expr]

ppr_expr (HsLet binds expr)
  = sep [hang (ptext (sLit "let")) 2 (pprBinds binds),
         hang (ptext (sLit "in"))  2 (ppr expr)]

ppr_expr (HsAlet binds expr _ _ _ _)
  = sep [hang (ptext (sLit "alet")) 2 (pprBinds binds),
         hang (ptext (sLit "in"))  2 (ppr expr)]

ppr_expr (HsDo do_or_list_comp stmts _) = pprDo do_or_list_comp stmts

ppr_expr (ExplicitList _ exprs)
  = brackets (pprDeeperList fsep (punctuate comma (map ppr_lexpr exprs)))

ppr_expr (ExplicitPArr _ exprs)
  = pa_brackets (pprDeeperList fsep (punctuate comma (map ppr_lexpr exprs)))

ppr_expr (RecordCon con_id _ rbinds)
  = hang (ppr con_id) 2 (ppr rbinds)

ppr_expr (RecordUpd aexp rbinds _ _ _)
  = hang (pprParendExpr aexp) 2 (ppr rbinds)

ppr_expr (ExprWithTySig expr sig)
  = hang (nest 2 (ppr_lexpr expr) <+> dcolon)
         4 (ppr sig)
ppr_expr (ExprWithTySigOut expr sig)
  = hang (nest 2 (ppr_lexpr expr) <+> dcolon)
         4 (ppr sig)

ppr_expr (ArithSeq _ info) = brackets (ppr info)
ppr_expr (PArrSeq  _ info) = pa_brackets (ppr info)

ppr_expr EWildPat       = char '_'
ppr_expr (ELazyPat e)   = char '~' <> pprParendExpr e
ppr_expr (EAsPat v e)   = ppr v <> char '@' <> pprParendExpr e
ppr_expr (EViewPat p e) = ppr p <+> ptext (sLit "->") <+> ppr e

ppr_expr (HsSCC lbl expr)
  = sep [ ptext (sLit "_scc_") <+> doubleQuotes (ftext lbl),
          pprParendExpr expr ]

ppr_expr (HsWrap co_fn e) = pprHsWrapper (pprExpr e) co_fn
ppr_expr (HsType id)      = ppr id

ppr_expr (HsSpliceE s)       = pprSplice s
ppr_expr (HsBracket b)       = pprHsBracket b
ppr_expr (HsBracketOut e []) = ppr e
ppr_expr (HsBracketOut e ps) = ppr e $$ ptext (sLit "pending") <+> ppr ps
ppr_expr (HsQuasiQuoteE qq)  = ppr qq

ppr_expr (HsProc pat (L _ (HsCmdTop cmd _ _ _)))
  = hsep [ptext (sLit "proc"), ppr pat, ptext (sLit "->"), ppr cmd]

ppr_expr (HsTick tickish exp)
  = pprTicks (ppr exp) $
    ppr tickish <+> ppr exp
ppr_expr (HsBinTick tickIdTrue tickIdFalse exp)
  = pprTicks (ppr exp) $
    hcat [ptext (sLit "bintick<"),
          ppr tickIdTrue,
          ptext (sLit ","),
          ppr tickIdFalse,
          ptext (sLit ">("),
          ppr exp,ptext (sLit ")")]
ppr_expr (HsTickPragma externalSrcLoc exp)
  = pprTicks (ppr exp) $
    hcat [ptext (sLit "tickpragma<"),
          ppr externalSrcLoc,
          ptext (sLit ">("),
          ppr exp,
          ptext (sLit ")")]

ppr_expr (HsArrApp arrow arg _ HsFirstOrderApp True)
  = hsep [ppr_lexpr arrow, ptext (sLit "-<"), ppr_lexpr arg]
ppr_expr (HsArrApp arrow arg _ HsFirstOrderApp False)
  = hsep [ppr_lexpr arg, ptext (sLit ">-"), ppr_lexpr arrow]
ppr_expr (HsArrApp arrow arg _ HsHigherOrderApp True)
  = hsep [ppr_lexpr arrow, ptext (sLit "-<<"), ppr_lexpr arg]
ppr_expr (HsArrApp arrow arg _ HsHigherOrderApp False)
  = hsep [ppr_lexpr arg, ptext (sLit ">>-"), ppr_lexpr arrow]

ppr_expr (HsArrForm (L _ (HsVar v)) (Just _) [arg1, arg2])
  = sep [pprCmdArg (unLoc arg1), hsep [pprInfixOcc v, pprCmdArg (unLoc arg2)]]
ppr_expr (HsArrForm op _ args)
  = hang (ptext (sLit "(|") <> ppr_lexpr op)
         4 (sep (map (pprCmdArg.unLoc) args) <> ptext (sLit "|)"))

pprCmdArg :: OutputableBndr id => HsCmdTop id -> SDoc
pprCmdArg (HsCmdTop cmd@(L _ (HsArrForm _ Nothing [])) _ _ _)
  = ppr_lexpr cmd
pprCmdArg (HsCmdTop cmd _ _ _)
  = parens (ppr_lexpr cmd)

instance OutputableBndr id => Outputable (HsCmdTop id) where
    ppr = pprCmdArg

-- add parallel array brackets around a document
--
pa_brackets :: SDoc -> SDoc
pa_brackets p = ptext (sLit "[:") <> p <> ptext (sLit ":]")
\end{code}

HsSyn records exactly where the user put parens, with HsPar.
So generally speaking we print without adding any parens.
However, some code is internally generated, and in some places
parens are absolutely required; so for these places we use
pprParendExpr (but don't print double parens of course).

For operator applications we don't add parens, because the oprerator
fixities should do the job, except in debug mode (-dppr-debug) so we
can see the structure of the parse tree.

\begin{code}
pprDebugParendExpr :: OutputableBndr id => LHsExpr id -> SDoc
pprDebugParendExpr expr
  = getPprStyle (\sty ->
    if debugStyle sty then pprParendExpr expr
                      else pprLExpr      expr)

pprParendExpr :: OutputableBndr id => LHsExpr id -> SDoc
pprParendExpr expr
  | hsExprNeedsParens (unLoc expr) = parens (pprLExpr expr)
  | otherwise                      = pprLExpr expr
        -- Using pprLExpr makes sure that we go 'deeper'
        -- I think that is usually (always?) right

hsExprNeedsParens :: HsExpr id -> Bool
-- True of expressions for which '(e)' and 'e' 
-- mean the same thing
hsExprNeedsParens (ArithSeq {})       = False
hsExprNeedsParens (PArrSeq {})        = False
hsExprNeedsParens (HsLit {})          = False
hsExprNeedsParens (HsOverLit {})      = False
hsExprNeedsParens (HsVar {})          = False
hsExprNeedsParens (HsIPVar {})        = False
hsExprNeedsParens (ExplicitTuple {})  = False
hsExprNeedsParens (ExplicitList {})   = False
hsExprNeedsParens (ExplicitPArr {})   = False
hsExprNeedsParens (HsPar {})          = False
hsExprNeedsParens (HsBracket {})      = False
hsExprNeedsParens (HsBracketOut _ []) = False
hsExprNeedsParens (HsDo sc _ _)
       | isListCompExpr sc            = False
hsExprNeedsParens _ = True


isAtomicHsExpr :: HsExpr id -> Bool 
-- True of a single token
isAtomicHsExpr (HsVar {})     = True
isAtomicHsExpr (HsLit {})     = True
isAtomicHsExpr (HsOverLit {}) = True
isAtomicHsExpr (HsIPVar {})   = True
isAtomicHsExpr (HsWrap _ e)   = isAtomicHsExpr e
isAtomicHsExpr (HsPar e)      = isAtomicHsExpr (unLoc e)
isAtomicHsExpr _              = False
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Commands (in arrow abstractions)}
%*                                                                      *
%************************************************************************

We re-use HsExpr to represent these.

\begin{code}
type HsCmd id = HsExpr id

type LHsCmd id = LHsExpr id

data HsArrAppType = HsHigherOrderApp | HsFirstOrderApp
  deriving (Data, Typeable)
\end{code}

The legal constructors for commands are:

  = HsArrApp ...                -- as above

  | HsArrForm ...               -- as above

  | HsApp       (HsCmd id)
                (HsExpr id)

  | HsLam       (Match  id)     -- kappa

  -- the renamer turns this one into HsArrForm
  | OpApp       (HsExpr id)     -- left operand
                (HsCmd id)      -- operator
                Fixity          -- Renamer adds fixity; bottom until then
                (HsCmd id)      -- right operand

  | HsPar       (HsCmd id)      -- parenthesised command

  | HsCase      (HsExpr id)
                [Match id]      -- bodies are HsCmd's
                SrcLoc

  | HsIf        (Maybe (SyntaxExpr id)) --  cond function
  					 (HsExpr id)     --  predicate
                (HsCmd id)      --  then part
                (HsCmd id)      --  else part
                SrcLoc

  | HsLet       (HsLocalBinds id)       -- let(rec)
                (HsCmd  id)

  | HsDo        (HsStmtContext Name)    -- The parameterisation is unimportant
                                        -- because in this context we never use
                                        -- the PatGuard or ParStmt variant
                [Stmt id]       -- HsExpr's are really HsCmd's
                PostTcType      -- Type of the whole expression
                SrcLoc

Top-level command, introducing a new arrow.
This may occur inside a proc (where the stack is empty) or as an
argument of a command-forming operator.

\begin{code}
type LHsCmdTop id = Located (HsCmdTop id)

data HsCmdTop id
  = HsCmdTop (LHsCmd id)
             [PostTcType]     -- types of inputs on the command's stack
             PostTcType       -- return type of the command
             (SyntaxTable id) -- after type checking:
                              -- names used in the command's desugaring
  deriving (Data, Typeable)
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Record binds}
%*                                                                      *
%************************************************************************

\begin{code}
type HsRecordBinds id = HsRecFields id (LHsExpr id)
\end{code}


%************************************************************************
%*                                                                      *
\subsection{@Match@, @GRHSs@, and @GRHS@ datatypes}
%*                                                                      *
%************************************************************************

@Match@es are sets of pattern bindings and right hand sides for
functions, patterns or case branches. For example, if a function @g@
is defined as:
\begin{verbatim}
g (x,y) = y
g ((x:ys),y) = y+1,
\end{verbatim}
then \tr{g} has two @Match@es: @(x,y) = y@ and @((x:ys),y) = y+1@.

It is always the case that each element of an @[Match]@ list has the
same number of @pats@s inside it.  This corresponds to saying that
a function defined by pattern matching must have the same number of
patterns in each equation.

\begin{code}
data MatchGroup id
  = MatchGroup
        [LMatch id]     -- The alternatives
        PostTcType      -- The type is the type of the entire group
                        --      t1 -> ... -> tn -> tr
                        -- where there are n patterns
  deriving (Data, Typeable)

type LMatch id = Located (Match id)

data Match id
  = Match
        [LPat id]               -- The patterns
        (Maybe (LHsType id))    -- A type signature for the result of the match
                                -- Nothing after typechecking
        (GRHSs id)
  deriving (Data, Typeable)

isEmptyMatchGroup :: MatchGroup id -> Bool
isEmptyMatchGroup (MatchGroup ms _) = null ms

matchGroupArity :: MatchGroup id -> Arity
matchGroupArity (MatchGroup [] _)
  = panic "matchGroupArity"     -- Precondition: MatchGroup is non-empty
matchGroupArity (MatchGroup (match:matches) _)
  = ASSERT( all ((== n_pats) . length . hsLMatchPats) matches )
    -- Assertion just checks that all the matches have the same number of pats
    n_pats
  where
    n_pats = length (hsLMatchPats match)

hsLMatchPats :: LMatch id -> [LPat id]
hsLMatchPats (L _ (Match pats _ _)) = pats

-- | GRHSs are used both for pattern bindings and for Matches
data GRHSs id
  = GRHSs {
      grhssGRHSs :: [LGRHS id],  -- ^ Guarded RHSs
      grhssLocalBinds :: (HsLocalBinds id) -- ^ The where clause
    } deriving (Data, Typeable)

type LGRHS id = Located (GRHS id)

-- | Guarded Right Hand Side.
data GRHS id = GRHS [LStmt id]   -- Guards
                    (LHsExpr id) -- Right hand side
  deriving (Data, Typeable)
\end{code}

We know the list must have at least one @Match@ in it.

\begin{code}
pprMatches :: (OutputableBndr idL, OutputableBndr idR) => HsMatchContext idL -> MatchGroup idR -> SDoc
pprMatches ctxt (MatchGroup matches _)
    = vcat (map (pprMatch ctxt) (map unLoc matches))
      -- Don't print the type; it's only a place-holder before typechecking

-- Exported to HsBinds, which can't see the defn of HsMatchContext
pprFunBind :: (OutputableBndr idL, OutputableBndr idR) => idL -> Bool -> MatchGroup idR -> SDoc
pprFunBind fun inf matches = pprMatches (FunRhs fun inf) matches

-- Exported to HsBinds, which can't see the defn of HsMatchContext
pprPatBind :: forall bndr id. (OutputableBndr bndr, OutputableBndr id)
           => LPat bndr -> GRHSs id -> SDoc
pprPatBind pat (grhss)
 = sep [ppr pat, nest 2 (pprGRHSs (PatBindRhs :: HsMatchContext id) grhss)]

pprMatch :: (OutputableBndr idL, OutputableBndr idR) => HsMatchContext idL -> Match idR -> SDoc
pprMatch ctxt (Match pats maybe_ty grhss)
  = sep [ sep (herald : map (nest 2 . pprParendLPat) other_pats)
        , nest 2 ppr_maybe_ty
        , nest 2 (pprGRHSs ctxt grhss) ]
  where
    (herald, other_pats)
        = case ctxt of
            FunRhs fun is_infix -> funBind fun is_infix
            AletRhs fun is_infix -> funBind fun is_infix
            LambdaExpr -> (char '\\', pats)
	    
            _  -> ASSERT( null pats1 )
                  (ppr pat1, [])	-- No parens around the single pat
    funBind fun is_infix | not is_infix = (ppr fun, pats)
                        -- f x y z = e
                        -- Not pprBndr; the AbsBinds will
                        -- have printed the signature
                         | null pats2 = (pp_infix, [])
                        -- x &&& y = e
                         | otherwise = (parens pp_infix, pats2)
                        -- (x &&& y) z = e
                where
                  pp_infix = pprParendLPat pat1 <+> ppr fun <+> pprParendLPat pat2

    (pat1:pats1) = pats
    (pat2:pats2) = pats1
    ppr_maybe_ty = case maybe_ty of
                        Just ty -> dcolon <+> ppr ty
                        Nothing -> empty


pprGRHSs :: (OutputableBndr idL, OutputableBndr idR)
         => HsMatchContext idL -> GRHSs idR -> SDoc
pprGRHSs ctxt (GRHSs grhss binds)
  = vcat (map (pprGRHS ctxt . unLoc) grhss)
 $$ ppUnless (isEmptyLocalBinds binds)
      (text "where" $$ nest 4 (pprBinds binds))

pprGRHS :: (OutputableBndr idL, OutputableBndr idR)
        => HsMatchContext idL -> GRHS idR -> SDoc

pprGRHS ctxt (GRHS [] expr)
 =  pp_rhs ctxt expr

pprGRHS ctxt (GRHS guards expr)
 = sep [char '|' <+> interpp'SP guards, pp_rhs ctxt expr]

pp_rhs :: OutputableBndr idR => HsMatchContext idL -> LHsExpr idR -> SDoc
pp_rhs ctxt rhs = matchSeparator ctxt <+> pprDeeper (ppr rhs)
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Do stmts and list comprehensions}
%*                                                                      *
%************************************************************************

\begin{code}
type LStmt id = Located (StmtLR id id)
type LStmtLR idL idR = Located (StmtLR idL idR)

type Stmt id = StmtLR id id

-- The SyntaxExprs in here are used *only* for do-notation and monad
-- comprehensions, which have rebindable syntax. Otherwise they are unused.
data StmtLR idL idR
  = LastStmt  -- Always the last Stmt in ListComp, MonadComp, PArrComp, 
    	      -- and (after the renamer) DoExpr, MDoExpr
              -- Not used for GhciStmt, PatGuard, which scope over other stuff
               (LHsExpr idR)
               (SyntaxExpr idR)   -- The return operator, used only for MonadComp
	       		   	  -- For ListComp, PArrComp, we use the baked-in 'return'
				  -- For DoExpr, MDoExpr, we don't appply a 'return' at all
	       		   	  -- See Note [Monad Comprehensions]
  | BindStmt (LPat idL)
             (LHsExpr idR)
             (SyntaxExpr idR) -- The (>>=) operator; see Note [The type of bind]
             (SyntaxExpr idR) -- The fail operator
             -- The fail operator is noSyntaxExpr
             -- if the pattern match can't fail

  | ExprStmt (LHsExpr idR)     -- See Note [ExprStmt]
             (SyntaxExpr idR) -- The (>>) operator
             (SyntaxExpr idR) -- The `guard` operator; used only in MonadComp
                              -- See notes [Monad Comprehensions]
             PostTcType       -- Element type of the RHS (used for arrows)

  | LetStmt  (HsLocalBindsLR idL idR)

  -- ParStmts only occur in a list/monad comprehension
  | ParStmt  [([LStmt idL], [idR])]
             (SyntaxExpr idR)           -- Polymorphic `mzip` for monad comprehensions
             (SyntaxExpr idR)           -- The `>>=` operator
             (SyntaxExpr idR)           -- Polymorphic `return` operator
	     		 		-- with type (forall a. a -> m a)
                                        -- See notes [Monad Comprehensions]
  	    -- After renaming, the ids are the binders 
  	    -- bound by the stmts and used after themp

  | TransStmt {
      trS_form  :: TransForm,
      trS_stmts :: [LStmt idL],      -- Stmts to the *left* of the 'group'
	            	              -- which generates the tuples to be grouped

      trS_bndrs :: [(idR, idR)],     -- See Note [TransStmt binder map]
				
      trS_using :: LHsExpr idR,
      trS_by :: Maybe (LHsExpr idR), 	-- "by e" (optional)
	-- Invariant: if trS_form = GroupBy, then grp_by = Just e

      trS_ret :: SyntaxExpr idR,      -- The monomorphic 'return' function for 
                                       -- the inner monad comprehensions
      trS_bind :: SyntaxExpr idR,     -- The '(>>=)' operator
      trS_fmap :: SyntaxExpr idR      -- The polymorphic 'fmap' function for desugaring
      		   	      	       -- Only for 'group' forms
    }                                  -- See Note [Monad Comprehensions]

  -- Recursive statement (see Note [How RecStmt works] below)
  | RecStmt
     { recS_stmts :: [LStmtLR idL idR]

        -- The next two fields are only valid after renaming
     , recS_later_ids :: [idR] -- The ids are a subset of the variables bound by the
  		               -- stmts that are used in stmts that follow the RecStmt

     , recS_rec_ids :: [idR]   -- Ditto, but these variables are the "recursive" ones,
                   	       -- that are used before they are bound in the stmts of
                   	       -- the RecStmt. 
	-- An Id can be in both groups
	-- Both sets of Ids are (now) treated monomorphically
	-- See Note [How RecStmt works] for why they are separate

	-- Rebindable syntax
     , recS_bind_fn :: SyntaxExpr idR -- The bind function
     , recS_ret_fn  :: SyntaxExpr idR -- The return function
     , recS_mfix_fn :: SyntaxExpr idR -- The mfix function

        -- These fields are only valid after typechecking
     , recS_later_rets :: [PostTcExpr] -- (only used in the arrow version)
     , recS_rec_rets :: [PostTcExpr] -- These expressions correspond 1-to-1
                                     -- with recS_later_ids and recS_rec_ids,
                                     -- and are the expressions that should be
                                     -- returned by the recursion.
                                     -- They may not quite be the Ids themselves,
                                     -- because the Id may be *polymorphic*, but
                                     -- the returned thing has to be *monomorphic*, 
				     -- so they may be type applications

      , recS_ret_ty :: PostTcType    -- The type of of do { stmts; return (a,b,c) }
      		       		     -- With rebindable syntax the type might not
				     -- be quite as simple as (m (tya, tyb, tyc)).
      }
  deriving (Data, Typeable)

data TransForm	 -- The 'f' below is the 'using' function, 'e' is the by function
  = ThenForm     -- then f               or    then f by e             (depending on trS_by)
  | GroupForm	   -- then group using f   or    then group by e using f (depending on trS_by)
  deriving (Data, Typeable)
\end{code}

Note [The type of bind in Stmts]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Some Stmts, notably BindStmt, keep the (>>=) bind operator.  
We do NOT assume that it has type  
    (>>=) :: m a -> (a -> m b) -> m b
In some cases (see Trac #303, #1537) it might have a more 
exotic type, such as
    (>>=) :: m i j a -> (a -> m j k b) -> m i k b
So we must be careful not to make assumptions about the type.
In particular, the monad may not be uniform throughout.

Note [TransStmt binder map]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The [(idR,idR)] in a TransStmt behaves as follows:

  * Before renaming: []

  * After renaming: 
    	  [ (x27,x27), ..., (z35,z35) ]
    These are the variables 
       bound by the stmts to the left of the 'group'
       and used either in the 'by' clause, 
                or     in the stmts following the 'group'
    Each item is a pair of identical variables.

  * After typechecking: 
    	  [ (x27:Int, x27:[Int]), ..., (z35:Bool, z35:[Bool]) ]
    Each pair has the same unique, but different *types*.
   
Note [ExprStmt]
~~~~~~~~~~~~~~~
ExprStmts are a bit tricky, because what they mean
depends on the context.  Consider the following contexts:

        A do expression of type (m res_ty)
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * ExprStmt E any_ty:   do { ....; E; ... }
                E :: m any_ty
          Translation: E >> ...

        A list comprehensions of type [elt_ty]
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * ExprStmt E Bool:   [ .. | .... E ]
                        [ .. | ..., E, ... ]
                        [ .. | .... | ..., E | ... ]
                E :: Bool
          Translation: if E then fail else ...

        A guard list, guarding a RHS of type rhs_ty
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * ExprStmt E Bool:   f x | ..., E, ... = ...rhs...
                E :: Bool
          Translation: if E then fail else ...

        A monad comprehension of type (m res_ty)
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * ExprStmt E Bool:   [ .. | .... E ]
                E :: Bool
          Translation: guard E >> ...

Array comprehensions are handled like list comprehensions.

Note [How RecStmt works]
~~~~~~~~~~~~~~~~~~~~~~~~
Example:
   HsDo [ BindStmt x ex

        , RecStmt { recS_rec_ids   = [a, c]
                  , recS_stmts 	   = [ BindStmt b (return (a,c))
                  	       	     , LetStmt a = ...b...
                  	       	     , BindStmt c ec ]
                  , recS_later_ids = [a, b]

        , return (a b) ]

Here, the RecStmt binds a,b,c; but
  - Only a,b are used in the stmts *following* the RecStmt,
  - Only a,c are used in the stmts *inside* the RecStmt
        *before* their bindings

Why do we need *both* rec_ids and later_ids?  For monads they could be
combined into a single set of variables, but not for arrows.  That
follows from the types of the respective feedback operators:

	mfix :: MonadFix m => (a -> m a) -> m a
	loop :: ArrowLoop a => a (b,d) (c,d) -> a b c

* For mfix, the 'a' covers the union of the later_ids and the rec_ids 
* For 'loop', 'c' is the later_ids and 'd' is the rec_ids 

Note [Typing a RecStmt]
~~~~~~~~~~~~~~~~~~~~~~~
A (RecStmt stmts) types as if you had written

  (v1,..,vn, _, ..., _) <- mfix (\~(_, ..., _, r1, ..., rm) ->
                        	 do { stmts 
                        	    ; return (v1,..vn, r1, ..., rm) })

where v1..vn are the later_ids
      r1..rm are the rec_ids

Note [Monad Comprehensions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Monad comprehensions require separate functions like 'return' and
'>>=' for desugaring. These functions are stored in the statements
used in monad comprehensions. For example, the 'return' of the 'LastStmt'
expression is used to lift the body of the monad comprehension:

  [ body | stmts ]
   =>
  stmts >>= \bndrs -> return body

In transform and grouping statements ('then ..' and 'then group ..') the
'return' function is required for nested monad comprehensions, for example:

  [ body | stmts, then f, rest ]
   =>
  f [ env | stmts ] >>= \bndrs -> [ body | rest ]

ExprStmts require the 'Control.Monad.guard' function for boolean
expressions:

  [ body | exp, stmts ]
   =>
  guard exp >> [ body | stmts ]

Parallel statements require the 'Control.Monad.Zip.mzip' function:

  [ body | stmts1 | stmts2 | .. ]
   =>
  mzip stmts1 (mzip stmts2 (..)) >>= \(bndrs1, (bndrs2, ..)) -> return body

In any other context than 'MonadComp', the fields for most of these
'SyntaxExpr's stay bottom.


\begin{code}
instance (OutputableBndr idL, OutputableBndr idR) => Outputable (StmtLR idL idR) where
    ppr stmt = pprStmt stmt

pprStmt :: (OutputableBndr idL, OutputableBndr idR) => (StmtLR idL idR) -> SDoc
pprStmt (LastStmt expr _)         = ifPprDebug (ptext (sLit "[last]")) <+> ppr expr
pprStmt (BindStmt pat expr _ _)   = hsep [ppr pat, ptext (sLit "<-"), ppr expr]
pprStmt (LetStmt binds)           = hsep [ptext (sLit "let"), pprBinds binds]
pprStmt (ExprStmt expr _ _ _)     = ppr expr
pprStmt (ParStmt stmtss _ _ _)    = hsep (map doStmts stmtss)
  where doStmts stmts = ptext (sLit "| ") <> ppr stmts

pprStmt (TransStmt { trS_stmts = stmts, trS_by = by, trS_using = using, trS_form = form })
  = sep (ppr_lc_stmts stmts ++ [pprTransStmt by using form])

pprStmt (RecStmt { recS_stmts = segment, recS_rec_ids = rec_ids
                 , recS_later_ids = later_ids })
  = ptext (sLit "rec") <+> 
    vcat [ braces (vcat (map ppr segment))
         , ifPprDebug (vcat [ ptext (sLit "rec_ids=") <> ppr rec_ids
                            , ptext (sLit "later_ids=") <> ppr later_ids])]

pprTransformStmt :: OutputableBndr id => [id] -> LHsExpr id -> Maybe (LHsExpr id) -> SDoc
pprTransformStmt bndrs using by
  = sep [ ptext (sLit "then") <+> ifPprDebug (braces (ppr bndrs))
        , nest 2 (ppr using)
        , nest 2 (pprBy by)]

pprTransStmt :: OutputableBndr id => Maybe (LHsExpr id)
                                  -> LHsExpr id -> TransForm
				  -> SDoc
pprTransStmt by using ThenForm
  = sep [ ptext (sLit "then"), nest 2 (ppr using), nest 2 (pprBy by)]
pprTransStmt by using GroupForm
  = sep [ ptext (sLit "then group"), nest 2 (pprBy by), nest 2 (ptext (sLit "using") <+> ppr using)]

pprBy :: OutputableBndr id => Maybe (LHsExpr id) -> SDoc
pprBy Nothing  = empty
pprBy (Just e) = ptext (sLit "by") <+> ppr e

pprDo :: OutputableBndr id => HsStmtContext any -> [LStmt id] -> SDoc
pprDo DoExpr      stmts = ptext (sLit "do")  <+> ppr_do_stmts stmts
pprDo GhciStmt    stmts = ptext (sLit "do")  <+> ppr_do_stmts stmts
pprDo ArrowExpr   stmts = ptext (sLit "do")  <+> ppr_do_stmts stmts
pprDo MDoExpr     stmts = ptext (sLit "mdo") <+> ppr_do_stmts stmts
pprDo ListComp    stmts = brackets    $ pprComp stmts
pprDo PArrComp    stmts = pa_brackets $ pprComp stmts
pprDo MonadComp   stmts = brackets    $ pprComp stmts
pprDo _           _     = panic "pprDo" -- PatGuard, ParStmtCxt

ppr_do_stmts :: OutputableBndr id => [LStmt id] -> SDoc
-- Print a bunch of do stmts, with explicit braces and semicolons,
-- so that we are not vulnerable to layout bugs
ppr_do_stmts stmts 
  = lbrace <+> pprDeeperList vcat (punctuate semi (map ppr stmts))
           <+> rbrace

ppr_lc_stmts :: OutputableBndr id => [LStmt id] -> [SDoc]
ppr_lc_stmts stmts = [ppr s <> comma | s <- stmts]

pprComp :: OutputableBndr id => [LStmt id] -> SDoc
pprComp quals	  -- Prints:  body | qual1, ..., qualn 
  | not (null quals)
  , L _ (LastStmt body _) <- last quals
  = hang (ppr body <+> char '|') 2 (interpp'SP (dropTail 1 quals))
  | otherwise
  = pprPanic "pprComp" (interpp'SP quals)
\end{code}

%************************************************************************
%*                                                                      *
                Template Haskell quotation brackets
%*                                                                      *
%************************************************************************

\begin{code}
data HsSplice id  = HsSplice            --  $z  or $(f 4)
                        id              -- The id is just a unique name to
                        (LHsExpr id)    -- identify this splice point
  deriving (Data, Typeable)

instance OutputableBndr id => Outputable (HsSplice id) where
  ppr = pprSplice

pprSplice :: OutputableBndr id => HsSplice id -> SDoc
pprSplice (HsSplice n e)
    = char '$' <> ifPprDebug (brackets (ppr n)) <> eDoc
    where
          -- We use pprLExpr to match pprParendExpr:
          --     Using pprLExpr makes sure that we go 'deeper'
          --     I think that is usually (always?) right
          pp_as_was = pprLExpr e
          eDoc = case unLoc e of
                 HsPar _ -> pp_as_was
                 HsVar _ -> pp_as_was
                 _ -> parens pp_as_was

data HsBracket id = ExpBr (LHsExpr id)   -- [|  expr  |]
                  | PatBr (LPat id)      -- [p| pat   |]
                  | DecBrL [LHsDecl id]	 -- [d| decls |]; result of parser
                  | DecBrG (HsGroup id)  -- [d| decls |]; result of renamer
                  | TypBr (LHsType id)   -- [t| type  |]
                  | VarBr Bool id        -- True: 'x, False: ''T
                                         -- (The Bool flag is used only in pprHsBracket)
  deriving (Data, Typeable)

instance OutputableBndr id => Outputable (HsBracket id) where
  ppr = pprHsBracket


pprHsBracket :: OutputableBndr id => HsBracket id -> SDoc
pprHsBracket (ExpBr e) 	 = thBrackets empty (ppr e)
pprHsBracket (PatBr p) 	 = thBrackets (char 'p') (ppr p)
pprHsBracket (DecBrG gp) = thBrackets (char 'd') (ppr gp)
pprHsBracket (DecBrL ds) = thBrackets (char 'd') (vcat (map ppr ds))
pprHsBracket (TypBr t) 	 = thBrackets (char 't') (ppr t)
pprHsBracket (VarBr True n)  = char '\''         <> ppr n
pprHsBracket (VarBr False n) = ptext (sLit "''") <> ppr n

thBrackets :: SDoc -> SDoc -> SDoc
thBrackets pp_kind pp_body = char '[' <> pp_kind <> char '|' <+>
                             pp_body <+> ptext (sLit "|]")
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Enumerations and list comprehensions}
%*                                                                      *
%************************************************************************

\begin{code}
data ArithSeqInfo id
  = From            (LHsExpr id)
  | FromThen        (LHsExpr id)
                    (LHsExpr id)
  | FromTo          (LHsExpr id)
                    (LHsExpr id)
  | FromThenTo      (LHsExpr id)
                    (LHsExpr id)
                    (LHsExpr id)
  deriving (Data, Typeable)
\end{code}

\begin{code}
instance OutputableBndr id => Outputable (ArithSeqInfo id) where
    ppr (From e1)             = hcat [ppr e1, pp_dotdot]
    ppr (FromThen e1 e2)      = hcat [ppr e1, comma, space, ppr e2, pp_dotdot]
    ppr (FromTo e1 e3)        = hcat [ppr e1, pp_dotdot, ppr e3]
    ppr (FromThenTo e1 e2 e3)
      = hcat [ppr e1, comma, space, ppr e2, pp_dotdot, ppr e3]

pp_dotdot :: SDoc
pp_dotdot = ptext (sLit " .. ")
\end{code}


%************************************************************************
%*                                                                      *
\subsection{HsMatchCtxt}
%*                                                                      *
%************************************************************************

\begin{code}
data HsMatchContext id  -- Context of a Match
  = FunRhs id Bool              -- Function binding for f; True <=> written infix
  | AletRhs id Bool             -- Alet binding; True <=> written infix
  | LambdaExpr                  -- Patterns of a lambda
  | CaseAlt                     -- Patterns and guards on a case alternative
  | ProcExpr                    -- Patterns of a proc
  | PatBindRhs                  -- A pattern binding  eg [y] <- e = e

  | RecUpd                      -- Record update [used only in DsExpr to
                                --    tell matchWrapper what sort of
                                --    runtime error message to generate]

  | StmtCtxt (HsStmtContext id) -- Pattern of a do-stmt, list comprehension, 
    	     		    	-- pattern guard, etc

  | ThPatQuote			-- A Template Haskell pattern quotation [p| (a,b) |]
  deriving (Data, Typeable)

data HsStmtContext id
  = ListComp
  | MonadComp
  | PArrComp                             -- Parallel array comprehension

  | DoExpr				 -- do { ... }
  | MDoExpr                              -- mdo { ... }  ie recursive do-expression 
  | ArrowExpr				 -- do-notation in an arrow-command context

  | GhciStmt				 -- A command-line Stmt in GHCi pat <- rhs
  | PatGuard (HsMatchContext id)         -- Pattern guard for specified thing
  | ParStmtCtxt (HsStmtContext id)       -- A branch of a parallel stmt
  | TransStmtCtxt (HsStmtContext id)     -- A branch of a transform stmt
  deriving (Data, Typeable)
\end{code}

\begin{code}
isListCompExpr :: HsStmtContext id -> Bool
-- Uses syntax [ e | quals ]
isListCompExpr ListComp  	 = True
isListCompExpr PArrComp  	 = True
isListCompExpr MonadComp 	 = True  
isListCompExpr (ParStmtCtxt c)   = isListCompExpr c
isListCompExpr (TransStmtCtxt c) = isListCompExpr c
isListCompExpr _                 = False

isMonadCompExpr :: HsStmtContext id -> Bool
isMonadCompExpr MonadComp            = True
isMonadCompExpr (ParStmtCtxt ctxt)   = isMonadCompExpr ctxt
isMonadCompExpr (TransStmtCtxt ctxt) = isMonadCompExpr ctxt
isMonadCompExpr _                    = False
\end{code}

\begin{code}
matchSeparator :: HsMatchContext id -> SDoc
matchSeparator (FunRhs {})  = ptext (sLit "=")
matchSeparator (AletRhs {}) = ptext (sLit "=")
matchSeparator CaseAlt      = ptext (sLit "->")
matchSeparator LambdaExpr   = ptext (sLit "->")
matchSeparator ProcExpr     = ptext (sLit "->")
matchSeparator PatBindRhs   = ptext (sLit "=")
matchSeparator (StmtCtxt _) = ptext (sLit "<-")
matchSeparator RecUpd       = panic "unused"
matchSeparator ThPatQuote   = panic "unused"
\end{code}

\begin{code}
pprMatchContext :: Outputable id => HsMatchContext id -> SDoc
pprMatchContext ctxt 
  | want_an ctxt = ptext (sLit "an") <+> pprMatchContextNoun ctxt
  | otherwise    = ptext (sLit "a")  <+> pprMatchContextNoun ctxt
  where
    want_an (FunRhs {}) = True	-- Use "an" in front
    want_an (AletRhs {}) = True	-- Use "an" in front
    want_an ProcExpr    = True
    want_an _           = False
                 
pprMatchContextNoun :: Outputable id => HsMatchContext id -> SDoc
pprMatchContextNoun (FunRhs fun _)  = ptext (sLit "equation for")
                                      <+> quotes (ppr fun)
pprMatchContextNoun (AletRhs fun _) = ptext (sLit "alet equation for")
                                      <+> quotes (ppr fun)
pprMatchContextNoun CaseAlt         = ptext (sLit "case alternative")
pprMatchContextNoun RecUpd          = ptext (sLit "record-update construct")
pprMatchContextNoun ThPatQuote      = ptext (sLit "Template Haskell pattern quotation")
pprMatchContextNoun PatBindRhs      = ptext (sLit "pattern binding")
pprMatchContextNoun LambdaExpr      = ptext (sLit "lambda abstraction")
pprMatchContextNoun ProcExpr        = ptext (sLit "arrow abstraction")
pprMatchContextNoun (StmtCtxt ctxt) = ptext (sLit "pattern binding in")
                                      $$ pprStmtContext ctxt

-----------------
pprAStmtContext, pprStmtContext :: Outputable id => HsStmtContext id -> SDoc
pprAStmtContext ctxt = article <+> pprStmtContext ctxt
  where
    pp_an = ptext (sLit "an")
    pp_a  = ptext (sLit "a")
    article = case ctxt of
                  MDoExpr  -> pp_an
                  PArrComp -> pp_an
		  GhciStmt -> pp_an
                  _        -> pp_a


-----------------
pprStmtContext GhciStmt        = ptext (sLit "interactive GHCi command")
pprStmtContext DoExpr          = ptext (sLit "'do' block")
pprStmtContext MDoExpr         = ptext (sLit "'mdo' block")
pprStmtContext ArrowExpr       = ptext (sLit "'do' block in an arrow command")
pprStmtContext ListComp        = ptext (sLit "list comprehension")
pprStmtContext MonadComp       = ptext (sLit "monad comprehension")
pprStmtContext PArrComp        = ptext (sLit "array comprehension")
pprStmtContext (PatGuard ctxt) = ptext (sLit "pattern guard for") $$ pprMatchContext ctxt

-- Drop the inner contexts when reporting errors, else we get
--     Unexpected transform statement
--     in a transformed branch of
--          transformed branch of
--          transformed branch of monad comprehension
pprStmtContext (ParStmtCtxt c)
 | opt_PprStyle_Debug = sep [ptext (sLit "parallel branch of"), pprAStmtContext c]
 | otherwise          = pprStmtContext c
pprStmtContext (TransStmtCtxt c)
 | opt_PprStyle_Debug = sep [ptext (sLit "transformed branch of"), pprAStmtContext c]
 | otherwise          = pprStmtContext c


-- Used to generate the string for a *runtime* error message
matchContextErrString :: Outputable id => HsMatchContext id -> SDoc
matchContextErrString (FunRhs fun _)             = ptext (sLit "function") <+> ppr fun
matchContextErrString (AletRhs fun _)            = ptext (sLit "alet definition") <+> ppr fun
matchContextErrString CaseAlt                    = ptext (sLit "case")
matchContextErrString PatBindRhs                 = ptext (sLit "pattern binding")
matchContextErrString RecUpd                     = ptext (sLit "record update")
matchContextErrString LambdaExpr                 = ptext (sLit "lambda")
matchContextErrString ProcExpr                   = ptext (sLit "proc")
matchContextErrString ThPatQuote                 = panic "matchContextErrString"  -- Not used at runtime
matchContextErrString (StmtCtxt (ParStmtCtxt c))   = matchContextErrString (StmtCtxt c)
matchContextErrString (StmtCtxt (TransStmtCtxt c)) = matchContextErrString (StmtCtxt c)
matchContextErrString (StmtCtxt (PatGuard _))      = ptext (sLit "pattern guard")
matchContextErrString (StmtCtxt GhciStmt)          = ptext (sLit "interactive GHCi command")
matchContextErrString (StmtCtxt DoExpr)            = ptext (sLit "'do' block")
matchContextErrString (StmtCtxt ArrowExpr)         = ptext (sLit "'do' block")
matchContextErrString (StmtCtxt MDoExpr)           = ptext (sLit "'mdo' block")
matchContextErrString (StmtCtxt ListComp)          = ptext (sLit "list comprehension")
matchContextErrString (StmtCtxt MonadComp)         = ptext (sLit "monad comprehension")
matchContextErrString (StmtCtxt PArrComp)          = ptext (sLit "array comprehension")
\end{code}

\begin{code}
pprMatchInCtxt :: (OutputableBndr idL, OutputableBndr idR)
	       => HsMatchContext idL -> Match idR -> SDoc
pprMatchInCtxt ctxt match  = hang (ptext (sLit "In") <+> pprMatchContext ctxt <> colon) 
			     4 (pprMatch ctxt match)

pprStmtInCtxt :: (OutputableBndr idL, OutputableBndr idR)
   	       => HsStmtContext idL -> StmtLR idL idR -> SDoc
pprStmtInCtxt ctxt (LastStmt e _)
  | isListCompExpr ctxt      -- For [ e | .. ], do not mutter about "stmts"
  = hang (ptext (sLit "In the expression:")) 2 (ppr e)

pprStmtInCtxt ctxt stmt 
  = hang (ptext (sLit "In a stmt of") <+> pprAStmtContext ctxt <> colon)
       2 (ppr_stmt stmt)
  where
    -- For Group and Transform Stmts, don't print the nested stmts!
    ppr_stmt (TransStmt { trS_by = by, trS_using = using
                        , trS_form = form }) = pprTransStmt by using form
    ppr_stmt stmt = pprStmt stmt
\end{code}
