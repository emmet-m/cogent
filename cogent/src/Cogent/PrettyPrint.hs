--
-- Copyright 2018, Data61
-- Commonwealth Scientific and Industrial Research Organisation (CSIRO)
-- ABN 41 687 119 230.
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(DATA61_GPL)
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-missing-signatures #-}

module Cogent.PrettyPrint where
import qualified Cogent.Common.Syntax as S (associativity)
import Cogent.Common.Syntax hiding (associativity)
import Cogent.Common.Types
import qualified Cogent.Common.Repr as R
import Cogent.Compiler
import Cogent.Reorganizer (ReorganizeError(..), SourceObject(..))
import Cogent.ReprCheck
import Cogent.Surface
-- import Cogent.TypeCheck --hiding (context)
import Cogent.TypeCheck.Assignment
import Cogent.TypeCheck.Base
import Cogent.TypeCheck.Subst
import qualified Cogent.TypeCheck.Row as Row
import Control.Arrow (second)
import qualified Data.Foldable as F
import Data.Function ((&))
import Data.IntMap as I (IntMap, toList, lookup)
import Data.List(intercalate,nub)
import qualified Data.Map as M hiding (foldr)
#if __GLASGOW_HASKELL__ < 709
import Data.Monoid (mconcat)
import Prelude hiding (foldr)
#else
import Prelude hiding ((<$>), foldr)
#endif
import Data.Word (Word32)
import System.FilePath (takeFileName)
import Text.Parsec.Pos
import Text.PrettyPrint.ANSI.Leijen hiding (indent, tupled)


-- pretty-printing theme definition
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- meta-level constructs

position = string
err = red . string
errbd = bold . err
warn = dullyellow . string
comment = black . string
context = black . string
context' = string

-- language ast

varname = string
letbangvar = dullgreen . string
primop = blue . string
keyword = bold . string
literal = dullcyan
reprname = dullcyan . string
typevar = blue . string
typename = blue . bold . string
typesymbol = cyan . string  -- type operators, e.g. !, ->, take
funname = green . string
funname' = underline . green . string
fieldname = magenta . string
tagname = dullmagenta . string
symbol = string
kindsig = red . string
typeargs [] = empty
typeargs xs = encloseSep lbracket rbracket (comma <> space) xs
array = encloseSep lbracket rbracket (comma <> space)
record = encloseSep (lbrace <> space) (space <> rbrace) (comma <> space)
variant = encloseSep (langle <> space) rangle (symbol "|" <> space) . map (<> space)

-- combinators, helpers

indentation :: Int
indentation = 3

indent = nest indentation
indent' = (string (replicate indentation ' ') <>) . indent

-- FIXME: no spaces within parens where elements are on multiple lines / zilinc
tupled = __fixme . encloseSep lparen rparen (comma <> space)
-- non-unit tuples. put parens subject to arity
tupled1 [x] = x
tupled1 x = __fixme $ encloseSep lparen rparen (comma <> space) x

spaceList = encloseSep empty empty space
commaList = encloseSep empty empty (comma <> space)


-- associativity
-- ~~~~~~~~~~~~~~~~

associativity :: String -> Associativity
associativity = S.associativity . symbolOp


-- type classes and instances for different constructs
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

class Prec a where  -- precedence
  prec :: a -> Int  -- smaller the number stronger the associativity

instance Prec () where
  prec _ = 0

instance Prec Associativity where
  prec (LeftAssoc  i) = i
  prec (RightAssoc i) = i
  prec (NoAssoc    i) = i
  prec (Prefix)       = 9  -- as in the expression builder

instance Prec (Expr t p ip e) where
  -- vvv terms
  prec (Var {}) = 0
  prec (TypeApp {}) = 0
  prec (BoolLit {}) = 0
  prec (Con _ []) = 0
  prec (IntLit {}) = 0
  prec (CharLit {}) = 0
  prec (StringLit {}) = 0
  prec (Unitel) = 0
  prec (Tuple {}) = 0
#ifdef BUILTIN_ARRAYS
  prec (ArrayLit {}) = 0
#endif
  prec (UnboxedRecord {}) = 0
  -- vvv parsed by the expression builder
  prec (Member {}) = 8
  prec (Upcast {}) = 9
  prec (App  _ _ False) = 9
  prec (AppC {}) = 9
  prec (Con _ _) = 9
  prec (Put {}) = 9
#ifdef BUILTIN_ARRAYS
  prec (ArrayIndex {}) = 10
#endif
  prec (Comp {}) = 10
  prec (PrimOp n _) = prec (associativity n)  -- range 11 - 19
  prec (Annot {}) = 30
  prec (App  _ _ True) = 31
  -- vvv expressions
  prec (Lam  {}) = 100
  prec (LamC {}) = 100
  prec (Seq {}) = 100
  prec (Match {}) = 100
  prec (If {}) = 100
  prec (MultiWayIf {}) = 100
  prec (Let {}) = 100

instance Prec RawExpr where
  prec (RE e) = prec e

instance Prec (TExpr t) where
  prec (TE _ e _) = prec e

instance Prec SExpr where
  prec (SE e) = prec e
  prec (SU _) = 0

-- NOTE: the difference from the definition of the fixity of Constraint
instance Prec Constraint where
  prec (_ :&  _) = 2
  prec (_ :@  _) = 1
  prec _ = 0

-- ------------------------------------

-- add parens and indents to expressions depending on level
prettyPrec :: (Pretty a, Prec a) => Int -> a -> Doc
prettyPrec l x | prec x < l = pretty x
               | otherwise  = parens (indent (pretty x))

-- ------------------------------------

class ExprType a where
  isVar :: a -> VarName -> Bool

instance ExprType (Expr t p ip e) where
  isVar (Var n) s = (n == s)
  isVar _ _ = False

instance ExprType RawExpr where
  isVar (RE e) = isVar e

instance ExprType (TExpr t) where
  isVar (TE _ e _) = isVar e

instance ExprType SExpr where
  isVar (SE e) = isVar e
  isVar (SU _) = const False

-- ------------------------------------

class PatnType a where
  isPVar  :: a -> VarName -> Bool
  prettyP :: a -> Doc
  prettyB :: (Pretty t, Pretty e, Prec e) => (a, Maybe t, e) -> Bool -> Doc  -- binding

instance (PrettyName pv, PatnType ip, Pretty ip) => PatnType (IrrefutablePattern pv ip) where
  isPVar (PVar pv) = isName pv
  isPVar _ = const False

  prettyP p@(PTake {}) = parens (pretty p)
  prettyP p = pretty p

  prettyB (p, Just t, e) i
    = group (pretty p <+> symbol ":" <+> pretty t <+> symbol "=" <+>
             (if i then (prettyPrec 100) else pretty) e)
  prettyB (p, Nothing, e) i
    = group (pretty p <+> symbol "=" <+>
             (if i then (prettyPrec 100) else pretty) e)

instance PatnType RawIrrefPatn where
  isPVar  (RIP p) = isPVar p
  prettyP (RIP p) = prettyP p
  prettyB (RIP p,mt,e) = prettyB (p,mt,e)

instance PatnType LocIrrefPatn where
  isPVar  (LocIrrefPatn _ p) = isPVar p
  prettyP (LocIrrefPatn _ p) = prettyP p
  prettyB (LocIrrefPatn _ p,mt,e) = prettyB (p,mt,e)

instance (Pretty t) => PatnType (TIrrefPatn t) where
  isPVar  (TIP p _) = isPVar p
  prettyP (TIP p _) = prettyP p
  prettyB (TIP p _,mt,e) = prettyB (p,mt,e)

instance (PatnType ip, Pretty ip) => PatnType (Pattern ip) where
  isPVar (PIrrefutable ip) = isPVar ip
  isPVar _ = const False

  prettyP (PIrrefutable ip) = prettyP ip
  prettyP p = pretty p

  prettyB (p, Just t, e) i
       = group (pretty p <+> symbol ":" <+> pretty t <+> symbol "<=" <+> (if i then (prettyPrec 100) else pretty) e)
  prettyB (p, Nothing, e) i
       = group (pretty p <+> symbol "<=" <+> (if i then (prettyPrec 100) else pretty) e)

instance PatnType RawPatn where
  isPVar  (RP p)= isPVar p
  prettyP (RP p) = prettyP p
  prettyB (RP p,mt,e) = prettyB (p,mt,e)

instance PatnType LocPatn where
  isPVar  (LocPatn _ p) = isPVar p
  prettyP (LocPatn _ p) = prettyP p
  prettyB (LocPatn _ p,mt,e) = prettyB (p,mt,e)

instance (Pretty t) => PatnType (TPatn t) where
  isPVar  (TP p _) = isPVar p
  prettyP (TP p _) = prettyP p
  prettyB (TP p _,mt,e) = prettyB (p,mt,e)

-- ------------------------------------

class TypeType t where
  isCon :: t -> Bool
  isTakePut :: t -> Bool
  isFun :: t -> Bool
  isAtomic :: t -> Bool

instance TypeType (Type e t) where
  isCon     (TCon {})  = True
  isCon     _          = False
  isFun     (TFun {})  = True
  isFun     _          = False
  isTakePut (TTake {}) = True
  isTakePut (TPut  {}) = True
  isTakePut _          = False
  isAtomic t | isFun t || isTakePut t = False
             | TCon _ (_:_) _ <- t = False
             | TUnbox _ <- t = False
             | TBang  _ <- t= False
             | otherwise = True

instance TypeType RawType where
  isCon     (RT t) = isCon     t
  isTakePut (RT t) = isTakePut t
  isFun     (RT t) = isFun     t
  isAtomic  (RT t) = isAtomic  t

instance TypeType TCType where
  isCon     (T t) = isCon t
  isCon     _     = False
  isFun     (T t) = isFun t
  isFun     _     = False
  isTakePut (T t) = isTakePut t
  isTakePut _     = False
  isAtomic  (T t) = isAtomic t
  isAtomic  _     = False

-- ------------------------------------

class PrettyName a where
  prettyName :: a -> Doc
  isName :: a -> String -> Bool

instance PrettyName VarName where
  prettyName = varname
  isName s = (== s)

instance Pretty t => PrettyName (VarName, t) where
  prettyName (a, b) | __cogent_fshow_types_in_pretty = parens $ prettyName a <+> comment "::" <+> pretty b
                    | otherwise = prettyName a
  isName (a, b) x = a == x

-- ------------------------------------

-- class Pretty

instance Pretty Word32 where
  pretty = integer . fromIntegral

instance Pretty Likelihood where
  pretty Likely   = symbol "=>"
  pretty Unlikely = symbol "~>"
  pretty Regular  = symbol "->"

instance (PrettyName pv, PatnType ip, Pretty ip) => Pretty (IrrefutablePattern pv ip) where
  pretty (PVar v) = prettyName v
  pretty (PTuple ps) = tupled (map pretty ps)
  pretty (PUnboxedRecord fs) = string "#" <> record (fmap handleTakeAssign fs)
  pretty (PUnderscore) = symbol "_"
  pretty (PUnitel) = string "()"
  pretty (PTake v fs) = prettyName v <+> record (fmap handleTakeAssign fs)
#ifdef BUILTIN_ARRAYS
  pretty (PArray ps) = array $ map pretty ps
#endif

instance Pretty RawIrrefPatn where
  pretty (RIP ip) = pretty ip

instance Pretty LocIrrefPatn where
  pretty (LocIrrefPatn _ ip) = pretty ip

instance Pretty t => Pretty (TIrrefPatn t) where
  pretty (TIP ip _) = pretty ip

instance (PatnType ip, Pretty ip) => Pretty (Pattern ip) where
  pretty (PCon c [] )     = tagname c
  pretty (PCon c [p])     = tagname c <+> prettyP p
  pretty (PCon c ps )     = tagname c <+> spaceList (map prettyP ps)
  pretty (PIntLit i)      = literal (string $ show i)
  pretty (PBoolLit b)     = literal (string $ show b)
  pretty (PCharLit c)     = literal (string $ show c)
  pretty (PIrrefutable p) = pretty p

instance Pretty RawPatn where
  pretty (RP p) = pretty p

instance Pretty LocPatn where
  pretty (LocPatn _ p) = pretty p

instance Pretty t => Pretty (TPatn t) where
  pretty (TP p _) = pretty p

instance (Pretty t, PatnType ip, PatnType p, Pretty p, Pretty e, Prec e) => Pretty (Binding t p ip e) where
  pretty (Binding p t e []) = prettyB (p,t,e) False
  pretty (Binding p t e bs)
     = prettyB (p,t,e) True <+> hsep (map (letbangvar . ('!':)) bs)
  pretty (BindingAlts p t e [] alts) = prettyB (p,t,e) False
                                    <> mconcat (map ((hardline <>) . indent . prettyA True) alts)
  pretty (BindingAlts p t e bs alts) = prettyB (p,t,e) True <+> hsep (map (letbangvar . ('!':)) bs)
                                    <> mconcat (map ((hardline <>) . indent . prettyA True) alts)

instance (Pretty p, Pretty e) => Pretty (Alt p e) where
  pretty (Alt p arrow e) = pretty p <+> group (pretty arrow <+> pretty e)

prettyA :: (Pretty p, Pretty e) 
        => Bool  -- is biased
        -> Alt p e
        -> Doc
prettyA False alt = symbol "|" <+> pretty alt
prettyA True alt = symbol "|>" <+> pretty alt

instance Pretty Inline where
  pretty Inline = keyword "inline" <+> empty
  pretty NoInline = empty

instance (ExprType e, Prec e, Pretty t, PatnType p, Pretty p, PatnType ip, Pretty ip, Pretty e) =>
         Pretty (Expr t p ip e) where
  pretty (Var x)             = varname x
  pretty (TypeApp x ts note) = pretty note <> varname x
                                 <> typeargs (map (\case Nothing -> symbol "_"; Just t -> pretty t) ts)
  pretty (Member x f)        = prettyPrec 9 x <> symbol "." <> fieldname f
  pretty (IntLit i)          = literal (string $ show i)
  pretty (BoolLit b)         = literal (string $ show b)
  pretty (CharLit c)         = literal (string $ show c)
  pretty (StringLit s)       = literal (string $ show s)
#ifdef BUILTIN_ARRAYS
  pretty (ArrayLit es)       = array $ map pretty es
  pretty (ArrayIndex e i)    = prettyPrec 11 e <+> symbol "@" <+> prettyPrec 10 i
#endif
  pretty (Unitel)            = string "()"
  pretty (PrimOp n [a,b])
     | LeftAssoc  l <- associativity n = prettyPrec (l+1) a <+> primop n <+> prettyPrec l     b
     | RightAssoc l <- associativity n = prettyPrec l     a <+> primop n <+> prettyPrec (l+1) b
     | NoAssoc    l <- associativity n = prettyPrec l     a <+> primop n <+> prettyPrec l     b
  pretty (PrimOp n [e]) 
     | a  <- associativity n = primop n <+> prettyPrec (prec a) e
  pretty (PrimOp n es)       = primop n <+> tupled (map pretty es)
  pretty (Upcast e)          = keyword "upcast" <+> prettyPrec 9 e
  pretty (Lam p mt e)        = string "\\" <> pretty p <> 
                               (case mt of Nothing -> empty; Just t -> space <> symbol ":" <+> pretty t) <+> symbol "=>" <+> prettyPrec 101 e
  pretty (LamC p mt e _)     = pretty (Lam p mt e :: Expr t p ip e)
  pretty (App  a b False)    = prettyPrec 10 a <+> prettyPrec 9 b
  pretty (App  a b True )    = prettyPrec 31 a <+> symbol "$" <+> prettyPrec 32 b
  pretty (Comp f g)          = prettyPrec 10 f <+> symbol "o" <+> prettyPrec 9 g
  pretty (AppC a b)          = prettyPrec 10 a <+> prettyPrec 9 b
  pretty (Con n [] )         = tagname n
  pretty (Con n es )         = tagname n <+> spaceList (map (prettyPrec 9) es)
  pretty (Tuple es)          = tupled (map pretty es)
  pretty (UnboxedRecord fs)  = string "#" <> record (map (handlePutAssign . Just) fs)
  pretty (If c vs t e)       = group (keyword "if" <+> handleBangedIf vs (prettyPrec 100 c)
                                                   <$> indent (keyword "then" </> pretty t)
                                                   <$> indent (keyword "else" </> pretty e))
    where handleBangedIf []  = id
          handleBangedIf vs  = (<+> hsep (map (letbangvar . ('!':)) vs))
  pretty (MultiWayIf es el)  = keyword "if" <+> mconcat (map ((hardline <>) . indent . (symbol "|" <+>) . prettyBranch) es)
                                            <> hardline <> indent (symbol "|" <+> keyword "else" <+> symbol "->" <+> pretty el)
    where handleBangedIf []  = id
          handleBangedIf vs  = (<+> hsep (map (letbangvar . ('!':)) vs))

          prettyBranch (c,bs,l,e) = handleBangedIf bs (prettyPrec 100 c) <+> pretty l <+> pretty e
  pretty (Match e [] alts)   = prettyPrec 100 e
                               <> mconcat (map ((hardline <>) . indent . prettyA False) alts)
  -- vvv It's a hack here. See the notes in <tests/pass_letbang-cond-type-annot.cogent>
  pretty (Match e bs alts)   = handleLetBangs bs (prettyPrec 30 e)
                               <> mconcat (map ((hardline <>) . indent . prettyA False) alts)
    where handleLetBangs bs  = (<+> hsep (map (letbangvar . ('!':)) bs))
  pretty (Seq a b)           = prettyPrec 100 a <> symbol ";" <$> pretty b
  pretty (Let []     e)      = __impossible "pretty (in RawExpr)"
  pretty (Let (b:[]) e)      = keyword "let" <+> indent (pretty b)
                                             <$> keyword "in" <+> indent (pretty e)
  pretty (Let (b:bs) e)      = keyword "let" <+> indent (pretty b)
                                             <$> vsep (map ((keyword "and" <+>) . indent . pretty) bs)
                                             <$> keyword "in" <+> indent (pretty e)
  pretty (Put e fs)          = prettyPrec 10 e <+> record (map handlePutAssign fs)
  pretty (Annot e t)         = prettyPrec 31 e <+> symbol ":" <+> pretty t

instance Pretty RawExpr where
  pretty (RE e) = pretty e

instance Pretty t => Pretty (TExpr t) where
  pretty (TE t e _) | __cogent_fshow_types_in_pretty = parens $ pretty e <+> comment "::" <+> pretty t
                    | otherwise = pretty e

instance Pretty SExpr where
  pretty (SE e) = pretty e
  pretty (SU n) = warn ('?':show n)

prettyT' :: (TypeType t, Pretty t) => t -> Doc
prettyT' t | not $ isAtomic t = parens (pretty t)
           | otherwise        = pretty t

instance (Pretty t, TypeType t, Pretty e) => Pretty (Type e t) where
  pretty (TCon n [] s) = (if | readonly s -> (<> typesymbol "!")
                             | s == Unboxed && n `notElem` primTypeCons -> (typesymbol "#" <>)
                             | otherwise -> id) $ typename n
  pretty (TCon n as s) = (if | readonly s -> (<> typesymbol "!") . parens
                             | s == Unboxed -> ((typesymbol "#" <>) . parens)
                             | otherwise -> id) $
                         typename n <+> hsep (map prettyT' as)
  pretty (TVar n b u) = (if u then typesymbol "#" else empty) <> typevar n <> (if b then typesymbol "!" else empty)
  pretty (TTuple ts) = tupled (map pretty ts)
  pretty (TUnit)     = typesymbol "()" & (if __cogent_fdisambiguate_pp then (<+> comment "{- unit -}") else id)
#ifdef BUILTIN_ARRAYS
  pretty (TArray t l) = prettyT' t <> brackets (pretty l)
#endif
  pretty (TRecord ts s)
    | not . or $ map (snd . snd) ts = (if | s == Unboxed -> (typesymbol "#" <>)
                                          | readonly s -> (<> typesymbol "!")
                                          | otherwise -> id) $
        record (map (\(a,(b,c)) -> fieldname a <+> symbol ":" <+> pretty b) ts)  -- all untaken
    | otherwise = pretty (TRecord (map (second . second $ const False) ts) s :: Type e t)
              <+> typesymbol "take" <+> tupled1 (map fieldname tk)
        where tk = map fst $ filter (snd . snd) ts
  pretty (TVariant ts) | any snd ts = let
     names = map fst $ filter (snd . snd) $ M.toList ts
   in pretty (TVariant $ fmap (second (const False)) ts :: Type e t)
        <+> typesymbol "take"
        <+> tupled1 (map fieldname names)
  pretty (TVariant ts) = variant (map (\(a,bs) -> case bs of
                                          [] -> tagname a
                                          _  -> tagname a <+> spaceList (map prettyT' bs)) $ M.toList (fmap fst ts))
  pretty (TFun t t') = prettyT' t <+> typesymbol "->" <+> prettyT' t'
    where prettyT' e | isFun e   = parens (pretty e)
                     | otherwise = pretty e
  pretty (TUnbox t) = (typesymbol "#" <> prettyT' t) & (if __cogent_fdisambiguate_pp then (<+> comment "{- unbox -}") else id)
  pretty (TBang t) = (prettyT' t <> typesymbol "!") & (if __cogent_fdisambiguate_pp then (<+> comment "{- bang -}") else id)
  pretty (TTake fs x) = (prettyT' x <+> typesymbol "take"
                                    <+> case fs of Nothing  -> tupled (fieldname ".." : [])
                                                   Just fs' -> tupled1 (map fieldname fs'))
                        & (if __cogent_fdisambiguate_pp then (<+> comment "{- take -}") else id)
  pretty (TPut fs x) = (prettyT' x <+> typesymbol "put"
                                   <+> case fs of Nothing -> tupled (fieldname ".." : [])
                                                  Just fs' -> tupled1 (map fieldname fs'))
                       & (if __cogent_fdisambiguate_pp then (<+> comment "{- put -}") else id)

instance Pretty RawType where
  pretty (RT t) = pretty t

instance Pretty TCType where
  pretty (T t) = pretty t
  pretty t@(V v) = symbol "V <" <+> pretty v <+> symbol ">"
  pretty t@(R v s) =
    let sigilPretty = case s of
                        Left s -> pretty s
                        Right n -> symbol $ "(?" ++ show n ++ ")"
     in symbol "R {" <+> pretty v <+> symbol "}" <+> sigilPretty
  pretty (U v) = warn ('?':show v)
  pretty (Synonym n ts) = warn ('S':show n) <+> spaceList (map pretty ts)
--  pretty (RemoveCase a b) = pretty a <+> string "(without pattern" <+> pretty b <+> string ")"

instance Pretty LocType where
  pretty t = pretty (stripLocT t)

renderPolytypeHeader vs = keyword "all" <> tupled (map prettyKS vs) <> symbol "." 
    where prettyKS (v,K False False False) = typevar v
          prettyKS (v,k) = typevar v <+> symbol ":<" <+> pretty k

instance Pretty t => Pretty (Polytype t) where
  pretty (PT [] t) = pretty t
  pretty (PT vs t) = renderPolytypeHeader vs <+> pretty t

renderTypeDecHeader n vs = keyword "type" <+> typename n <> hcat (map ((space <>) . typevar) vs)
                                          <+> symbol "=" 

prettyFunDef :: (Pretty p, Pretty e, Pretty t) => Bool -> FunName -> Polytype t -> [Alt p e] -> Doc
prettyFunDef typeSigs v pt [Alt p Regular e] = (if typeSigs then (funname v <+> symbol ":" <+> pretty pt <$>) else id)
                                                 (funname v <+> pretty p <+> group (indent (symbol "=" <$> pretty e)))
prettyFunDef typeSigs v pt alts = (if typeSigs then (funname v <+> symbol ":" <+> pretty pt <$>) else id) $
                                       (indent (funname v <> mconcat (map ((hardline <>) . indent . prettyA False) alts)))

prettyConstDef typeSigs v t e  = (if typeSigs then (funname v <+> symbol ":" <+> pretty t <$>) else id) $
                                         (funname v <+> group (indent (symbol "=" <+> pretty e)))

instance (Pretty t, Pretty p, Pretty e) => Pretty (TopLevel t p e) where
  pretty (TypeDec n vs t) = keyword "type" <+> typename n <> hcat (map ((space <>) . typevar) vs)
                                           <+> indent (symbol "=" </> pretty t)
  pretty (RepDef f) = pretty f
  pretty (FunDef v pt alts) = prettyFunDef True v pt alts
  pretty (AbsDec v pt) = funname v <+> symbol ":" <+> pretty pt
  pretty (Include s) = keyword "include" <+> literal (string $ show s)
  pretty (IncludeStd s) = keyword "include <" <+> literal (string $ show s)
  pretty (AbsTypeDec n vs ts) = keyword "type" <+> typename n  <> hcat (map ((space <>) . typevar) vs)
                             <> (if F.null ts then empty else empty <+> symbol "-:" <+> commaList (map pretty ts))
  pretty (ConstDef v t e) = prettyConstDef True v t e
  pretty (DocBlock _) = __fixme empty  -- FIXME: doesn't PP docs right now

instance Pretty Kind where
  pretty k = kindsig (stringFor k)
    where stringFor k = (if canDiscard k then "D" else "")
                     ++ (if canShare   k then "S" else "")
                     ++ (if canEscape  k then "E" else "")

instance Pretty SourcePos where
  pretty p | __cogent_ffull_src_path = position (show p)
           | otherwise = position $ show $ setSourceName p (takeFileName $ sourceName p)

instance Pretty RepDecl where
  pretty (RepDecl _ n e) = keyword "repr" <+> reprname n <+> indent (symbol "=" </> pretty e)

instance Pretty RepSize where
  pretty (Bits b) = literal (string (show b ++ "b"))
  pretty (Bytes b) = literal (string (show b ++ "B"))
  pretty (Add a b) = pretty a <+> symbol "+" <+> pretty b

instance Pretty RepExpr where 
  pretty (RepRef n) = reprname n
  pretty (Prim sz) = pretty sz
  pretty (Offset e s) = pretty e <+> keyword "at" <+> pretty s
  pretty (Record fs) = keyword "record" <+> record (map (\(f,_,e) -> fieldname f <> symbol ":" <+> pretty e ) fs)
  pretty (Variant e vs) = keyword "variant" <+> tupled [pretty e]
                                                 <+> record (map (\(f,_,i,e) -> tagname f <+> tupled [literal $ string $ show i] <> symbol ":" <+> pretty e) vs)


instance Pretty Metadata where
  pretty (Constant {constName})              = err "the binding" <+> funname constName <$> err "is a global constant"
  pretty (Reused {varName, boundAt, usedAt}) = err "the variable" <+> varname varName
                                               <+> err "bound at" <+> pretty boundAt <> err ""
                                               <$> err "was already used at"
                                               <$> indent' (vsep $ map pretty $ F.toList usedAt)
  pretty (Unused {varName, boundAt}) = err "the variable" <+> varname varName
                                       <+> err "bound at" <+> pretty boundAt <> err ""
                                       <$> err "was never used."
  pretty (UnusedInOtherBranch {varName, boundAt, usedAt}) =
    err "the variable" <+> varname varName
    <+> err "bound at" <+> pretty boundAt <> err ""
    <$> err "was used in another branch of control at"
    <$> indent' (vsep $ map pretty $ F.toList usedAt)
    <$> err "but not this one."
  pretty (UnusedInThisBranch {varName, boundAt, usedAt}) =
    err "the variable" <+> varname varName
    <+> err "bound at" <+> pretty boundAt <> err ""
    <$> err "was used in this branch of control at"
    <$> indent' (vsep $ map pretty $ F.toList usedAt)
    <$> err "but not in all other branches."
  pretty Suppressed = err "a binder for a value of this type is being suppressed."
  pretty (UsedInMember {fieldName}) = err "the field" <+> fieldname fieldName
                                       <+> err "is being extracted without taking the field in a pattern."
#ifdef BUILTIN_ARRAYS
  pretty UsedInArrayIndexing = err "an element of the array is being extracted"
#endif
  pretty UsedInLetBang = err "it is being returned from such a context."
  pretty (TypeParam {functionName, typeVarName }) = err "it is required by the type of" <+> funname functionName
                                                      <+> err "(type variable" <+> typevar typeVarName <+> err ")"
  pretty ImplicitlyTaken = err "it is implicitly taken via subtyping."

instance Pretty FuncOrVar where
  pretty MustFunc  = err "Function"
  pretty MustVar   = err "Variable"
  pretty FuncOrVar = err "Variable or function"

instance Pretty TypeError where
  pretty (DifferingNumberOfConArgs f n m) = err "Constructor" <+> tagname f 
                                        <+> err "invoked with differing number of arguments (" <> int n <> err " vs " <> int m <> err ")"
  pretty (DuplicateTypeVariable vs)      = err "Duplicate type variable(s)" <+> commaList (map typevar vs)
  pretty (SuperfluousTypeVariable vs)    = err "Superfluous type variable(s)" <+> commaList (map typevar vs)
  pretty (DuplicateRecordFields fs)      = err "Duplicate record field(s)" <+> commaList (map fieldname fs)
  pretty (FunctionNotFound fn)           = err "Function" <+> funname fn <+> err "not found"
  pretty (TooManyTypeArguments fn pt)    = err "Too many type arguments to function"
                                           <+> funname fn  <+> err "of type" <+> pretty pt
  pretty (NotInScope fov vn)             = pretty fov <+> varname vn <+> err "not in scope"
  pretty (UnknownTypeVariable vn)        = err "Unknown type variable" <+> typevar vn
  pretty (UnknownTypeConstructor tn)     = err "Unknown type constructor" <+> typename tn
  pretty (TypeArgumentMismatch tn provided required)
                                         = typename tn <+> err "expects"
                                           <+> int required <+> err "arguments, but has been given" <+> int provided
  pretty (TypeMismatch t1 t2)            = err "Mismatch between" <$> indent' (pretty t1)
                                           <$> err "and" <$> indent' (pretty t2)
  pretty (RequiredTakenField f t)        = err "Field" <+> fieldname f <+> err "of type" <+> pretty t
                                           <+> err "is required, but has been taken"
  pretty (TypeNotShareable t m)          = err "Cannot share type" <+> pretty t
                                           <$> err "but this is needed as" <+> pretty m
  pretty (TypeNotEscapable t m)          = err "Cannot let type" <+> pretty t <+> err "escape from a !-ed context,"
  pretty (TypeNotDiscardable t m)        = err "Cannot discard type" <+> pretty t
                                           <+> err "but this is needed as" <+> pretty m
  pretty (PatternsNotExhaustive t tags)  = err "Patterns not exhaustive for type" <+> pretty t
                                           <$> err "cases not matched" <+> tupled1 (map tagname tags)
  pretty (UnsolvedConstraint c os)       = analyseLeftover c os
  pretty (RecordWildcardsNotSupported)   = err "Record wildcards are not supported"
  pretty (NotAFunctionType t)            = err "Type" <+> pretty t <+> err "is not a function type"
  pretty (DuplicateVariableInPattern vn) = err "Duplicate variable" <+> varname vn <+> err "in pattern"
  -- pretty (DuplicateVariableInPattern vn pat)       = err "Duplicate variable" <+> varname vn <+> err "in pattern:"
  --                                                    <$> pretty pat
  -- pretty (DuplicateVariableInIrrefPattern vn ipat) = err "Duplicate variable" <+> varname vn <+> err "in (irrefutable) pattern:"
  --                                                    <$> pretty ipat
  pretty (TakeFromNonRecordOrVariant fs t) = err "Cannot" <+> keyword "take" <+> err "fields"
                                             <+> (case fs of Nothing  -> tupled (fieldname ".." : [])
                                                             Just fs' -> tupled1 (map fieldname fs'))
                                             <+> err "from non record/variant type:"
                                             <$> indent' (pretty t)
  pretty (PutToNonRecordOrVariant fs t)    = err "Cannot" <+> keyword "put" <+> err "fields"
                                             <+> (case fs of Nothing  -> tupled (fieldname ".." : [])
                                                             Just fs' -> tupled1 (map fieldname fs'))
                                             <+> err "into non record/variant type:"
                                             <$> indent' (pretty t)
  pretty (TakeNonExistingField f t) = err "Cannot" <+> keyword "take" <+> err "non-existing field"
                                      <+> fieldname f <+> err "from record/variant" <$> indent' (pretty t)
  pretty (PutNonExistingField f t)  = err "Cannot" <+> keyword "put" <+> err "non-existing field"
                                      <+> fieldname f <+> err "into record/variant" <$> indent' (pretty t)
  pretty (DiscardWithoutMatch t)    = err "Variant tag"<+> tagname t <+> err "cannot be discarded without matching on it."
  pretty (RequiredTakenTag t)       = err "Required variant" <+> tagname t <+> err "but it has already been matched."
#ifdef BUILTIN_ARRAYS
  pretty (ArithConstraintsUnsatisfiable es msg) = err "The following arithmetic constraints are unsatisfiable" <> colon
                                              <$> indent' (vsep (map ((<> semi) . pretty) es))
                                              <$> err "The SMT-solver comments" <> colon
                                              <$> indent' (pretty msg)
#endif
  pretty (CustTyGenIsSynonym t)     = err "Type synonyms have to be fully expanded in --cust-ty-gen file:" <$> indent' (pretty t)
  pretty (CustTyGenIsPolymorphic t) = err "Polymorphic types are not allowed in --cust-ty-gen file:" <$> indent' (pretty t)
  pretty (RepError e) = pretty e
  pretty (TypeWarningAsError w)          = pretty w

instance Pretty TypeWarning where
  pretty (UnusedLocalBind v) = warn "[--Wunused-local-binds]" <$$> indent' (warn "Defined but not used:" <+> pretty v)
  pretty (TakeTakenField f t) = warn "[--Wdodgy-take-put]" <$$> indent' (warn "Take a taken field" <+> fieldname f
                                  <+> warn "from type" <$> pretty t)
  pretty (PutUntakenField f t) = warn "[--Wdodgy-take-put]" <$$> indent' (warn "Put an untaken field" <+> fieldname f
                                  <+> warn "into type" <$> pretty t)

instance Pretty TcLog where
  pretty = either ((err "Error:" <+>) . pretty) ((warn "Warning:" <+>) . pretty)

instance Pretty VarOrigin where
  pretty (ExpressionAt l) = warn ("the term at location " ++ show l)
  pretty (BoundOf a b d) = warn ("taking the " ++ show d ++ " of") <$> pretty a <$> warn "and" <$> pretty b

analyseLeftover :: Constraint -> I.IntMap VarOrigin -> Doc
{-
analyseLeftover c@(F t :< F u) os
    | Just t' <- flexOf t
    , Just u' <- flexOf u
    = vcat $ err "A subtyping constraint" <+>  pretty c <+> err "can't be solved because both sides are unknown."
           : map (\i -> warn "• The unknown" <+> pretty (U i) <+> warn "originates from" <+> pretty (I.lookup i os))
                 (nub [t',u'])
    | Just t' <- flexOf t
    = vcat $ (case t of
        U _ -> err "Constraint" <+> pretty c <+> err "can't be solved as another constraint blocks it."
        _   -> err "A subtyping constraint" <+>  pretty c
           <+> err "can't be solved because the LHS is unknown and uses non-injective operators (like !).")
             : map (\i -> warn "• The unknown" <+> pretty (U i) <+> warn "originates from" <+> pretty (I.lookup i os)) ([t'])
    | Just u' <- flexOf u
    = vcat $ (case u of
        U _ -> err "Constraint" <+> pretty c <+> err "can't be solved as another constraint blocks it."
        _   -> err "A subtyping constraint" <+>  pretty c
           <+> err "can't be solved because the RHS is unknown and uses non-injective operators (like !).")
             : map (\i -> warn "• The unknown" <+> pretty (U i) <+> warn "originates from" <+> pretty (I.lookup i os)) ([u']) -}
analyseLeftover c os = case c of
    Share x m  | Just x' <- flexOf x -> msg x' m
    Drop x m   | Just x' <- flexOf x -> msg x' m
    Escape x m | Just x' <- flexOf x -> msg x' m
    _ -> err "Leftover constraint!" <$> pretty c
  where msg i m = err "Constraint" <+> pretty c <+> err "can't be solved as it constrains an unknown."
                <$$> indent' (vcat [ warn "• The unknown" <+> pretty (U i) <+> warn "originates from" <+> pretty (I.lookup i os)
                                   , err "The constraint was emitted as" <+> pretty m])
{-
instance (Pretty t, TypeType t) => Pretty (TypeFragment t) where
  pretty (F t) = pretty t & (if __cogent_fdisambiguate_pp then (<+> comment "{- F -}") else id)
  pretty (FVariant ts) = typesymbol "?" <> pretty (TVariant ts :: Type SExpr t)
  pretty (FRecord ts)
    | not . or $ map (snd . snd) ts = typesymbol "?" <>
        record (map (\(a,(b,c)) -> fieldname a <+> symbol ":" <+> pretty b) ts)  -- all untaken
    | otherwise = pretty (FRecord (map (second . second $ const False) ts))
              <+> typesymbol "take" <+> tupled1 (map fieldname tk)
        where tk = map fst $ filter (snd .snd) ts
-}
instance Pretty Constraint where
  pretty (a :< b)         = pretty a </> warn ":<" </> pretty b
  pretty (a :=: b)        = pretty a </> warn ":=:" </> pretty b
  pretty (a :& b)         = prettyPrec 3 a </> warn ":&" </> prettyPrec 2 b
  pretty (Upcastable a b) = pretty a </> warn "~>" </> pretty b
  pretty (Share  t m)     = warn "Share" <+> pretty t
  pretty (Drop   t m)     = warn "Drop" <+> pretty t
  pretty (Escape t m)     = warn "Escape" <+> pretty t
  pretty (Unsat e)        = err  "Unsat"
  pretty (SemiSat w)      = warn "SemiSat"
  pretty (Sat)            = warn "Sat"
  pretty (Exhaustive t p) = warn "Exhaustive" <+> pretty t <+> pretty p
  pretty (Solved t)       = warn "Solved" <+> pretty t
  pretty (x :@ _)         = pretty x
#ifdef BUILTIN_ARRAYS
  pretty (Arith e)        = pretty e
#endif

-- a more verbose version of constraint pretty-printer which is mostly used for debugging
prettyC :: Constraint -> Doc
prettyC (Unsat e) = errbd "Unsat" <$> pretty e
prettyC (SemiSat w) = warn "SemiSat" -- <$> pretty w
prettyC (a :& b) = prettyCPrec 3 a </> warn ":&" <$> prettyCPrec 2 b
prettyC (c :@ e) = prettyCPrec 2 c & (if __cogent_ddump_tc_ctx then (</> prettyCtx e False) else (</> warn ":@ ..."))
prettyC c = pretty c

prettyCPrec :: Int -> Constraint -> Doc
prettyCPrec l x | prec x < l = prettyC x
                | otherwise  = parens (indent (prettyC x))

instance Pretty SourceObject where
  pretty (TypeName n) = typename n
  pretty (ValName  n) = varname n
  pretty (DocBlock' _) = __fixme empty  -- FIXME: not implemented

instance Pretty ReorganizeError where
  pretty CyclicDependency = err "cyclic dependency"
  pretty DuplicateTypeDefinition = err "duplicate type definition"
  pretty DuplicateValueDefinition = err "duplicate value definition"
  pretty DuplicateRepDefinition = err "duplicate repr definition"

instance Pretty Subst where
  pretty (Subst m) = pretty m

instance Pretty AssignResult where 
  pretty (Type t) = pretty t 
  pretty (Sigil s) = pretty s 
  pretty (Row r) = pretty r

instance Pretty (Sigil r) where
  pretty (Boxed False _) = keyword "[W]"
  pretty (Boxed True  _) = keyword "[R]"
  pretty Unboxed  = keyword "[U]"
instance (Pretty t) => Pretty (Row.Row t) where 
  pretty (Row.Row m t) =
    let rowFieldToDoc (_, (n, (ty, tk))) =
          let tkStr = case tk of
                        True -> "taken"
                        False -> "present"
          in text n <+> text ":" <+> pretty ty <+> text "(" <> text tkStr <> text ")"
        rowFieldsDoc = hsep $ punctuate (text ",") $ map rowFieldToDoc (M.toList m)
     in rowFieldsDoc <+> symbol "|" <+> pretty t
instance Pretty Assignment where
  pretty (Assignment m) = pretty m

instance Pretty a => Pretty (I.IntMap a) where
  pretty = vcat . map (\(k,v) -> pretty k <+> text "|->" <+> pretty v) . I.toList


instance Pretty RepError where 
  pretty (UnknownRepr r ctx) 
     = indent (err "Unknown representation" <+> reprname r <$$> pretty ctx)
  pretty (TagMustBeSingleBlock ctx) 
     = indent (err "Variant tag must be a single block of bits" <$$> pretty ctx)
  pretty (OverlappingBlocks (Block s1 o1 c1) (Block s2 o2 c2)) 
     = err "Two memory blocks are overlapping." <$$> 
       indent (err "The first block is of size" <+> literal (string $ show s1) <+> err "bits at offset" <+> literal (string $ show o1) <+> err "bits." <$$>
       -- TODO make the bits show up as bytes/bits.
       pretty c1) <$$>
       indent (err "The second block is of size" <+> literal (string $ show s2) <+> err "bits at offset" <+> literal (string $ show o2) <+> err "bits" <$$> 
       pretty c2)

instance Pretty RepContext where 
  pretty (InField n po ctx) = context' "for field" <+> fieldname n <+> context' "(" <> pretty po <> context' ")" </> pretty ctx 
  pretty (InTag ctx) = context' "for the variant tag block" </> pretty ctx
  pretty (InAlt t po ctx) = context' "for the constructor" <+> tagname t <+> context' "(" <> pretty po <> context' ")" </> pretty ctx 
  pretty (InDecl (RepDecl p n _)) = context' "in the representation" <+> reprname n <+> context' "(" <> pretty p <> context' ")" 

instance Pretty R.Representation where
  pretty (R.Bits s o) = keyword "repr" <> parens (pretty s <> symbol "+" <> pretty o)
  pretty (R.Variant ts to alts) = keyword "repr" <> parens (pretty ts <> symbol "+" <> pretty to)
                               <> variant (map prettyAlt $ M.toList alts)
    where prettyAlt (n,(v,r)) = tagname n <> parens (integer v) <> colon <> pretty r 
  pretty (R.Record fs) = keyword "repr" <> record (map prettyField $ M.toList fs)
    where prettyField (f,r) = fieldname f <> colon <> pretty r



-- helper functions
-- ~~~~~~~~~~~~~~~~~~~~~~~~~

-- assumes positive `n`
nth :: Int -> Doc
nth n = context $ show n ++ ordinalOf n

ordinalOf :: Int -> String
ordinalOf n =
  let (d,m) = divMod n 10
   in if d == 1
      then "th"
      else
        case m of
          1 -> "st"
          2 -> "nd"
          3 -> "rd"
          _ -> "th"


-- ctx -> indent -> doc
prettyCtx :: ErrorContext -> Bool -> Doc
prettyCtx (SolvingConstraint c) _ = context "from constraint" <+> indent (pretty c)
prettyCtx (ThenBranch) _ = context "in the" <+> keyword "then" <+> context "branch"
prettyCtx (ElseBranch) _ = context "in the" <+> keyword "else" <+> context "branch"
prettyCtx (NthBranch n) _ = context "in the" <+> nth n <+> context "branch of a multiway-if"
prettyCtx (InExpression e t) True = context "when checking that the expression at ("
                                      <> pretty (posOfE e) <> context ")"
                                      <$> (indent' (pretty (stripLocE e)))
                                      <$> context "has type" <$> (indent' (pretty t))
prettyCtx (InExpression e t) False = context "when checking the expression at ("
                                       <> pretty (posOfE e) <> context ")"
-- FIXME: more specific info for patterns
prettyCtx (InPattern p) True = context "when checking the pattern at ("
                                 <> pretty (posOfP p) <> context ")"
                                 <$> (indent' (pretty (stripLocP p)))
prettyCtx (InPattern p) False = context "when checking the pattern at ("
                                  <> pretty (posOfP p) <> context ")"
prettyCtx (InIrrefutablePattern ip) True = context "when checking the pattern at ("
                                             <> pretty (posOfIP ip) <> context ")"
                                             <$> (indent' (pretty (stripLocIP ip)))
prettyCtx (InIrrefutablePattern ip) False = context "when checking the pattern at ("
                                              <> pretty (posOfIP ip) <> context ")"
prettyCtx (NthAlternative n p) _ = context "in the" <+> nth n <+> context "alternative" <+> pretty p
prettyCtx (InDefinition p tl) _ = context "in the definition at (" <> pretty p <> context ")"
                               <$> context "for the" <+> helper tl
  where helper (TypeDec n _ _) = context "type synonym" <+> typename n
        helper (AbsTypeDec n _ _) = context "abstract type" <+> typename n
        helper (AbsDec n _) = context "abstract function" <+> varname n
        helper (ConstDef v _ _) = context "constant" <+> varname v
        helper (FunDef v _ _) = context "function" <+> varname v
        helper (RepDef (RepDecl _ n _)) = context "representation" <+> reprname n
        helper _  = __impossible "helper"
prettyCtx (AntiquotedType t) i = (if i then (<$> indent' (pretty (stripLocT t))) else id)
                               (context "in the antiquoted type at (" <> pretty (posOfT t) <> context ")" )
prettyCtx (AntiquotedExpr e) i = (if i then (<$> indent' (pretty (stripLocE e))) else id)
                               (context "in the antiquoted expression at (" <> pretty (posOfE e) <> context ")" )
prettyCtx (InAntiquotedCDefn n) _ = context "in the antiquoted C definition" <+> varname n
prettyCtx (CustomisedCodeGen t) _ = context "in customising code-generation for type" <+> pretty t

handleTakeAssign :: (PatnType ip, Pretty ip) => Maybe (FieldName, ip) -> Doc
handleTakeAssign Nothing = fieldname ".."
handleTakeAssign (Just (s, e)) | isPVar e s = fieldname s
handleTakeAssign (Just (s, e)) = fieldname s <+> symbol "=" <+> pretty e

handlePutAssign :: (ExprType e, Pretty e) => Maybe (FieldName, e) -> Doc
handlePutAssign Nothing = fieldname ".."
handlePutAssign (Just (s, e)) | isVar e s = fieldname s
handlePutAssign (Just (s, e)) = fieldname s <+> symbol "=" <+> pretty e


-- top-level function
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~

-- typechecker errors/warnings
prettyTWE :: Int -> ContextualisedTcLog -> Doc
prettyTWE th (ectx, l) = pretty l <$> indent' (vcat (map (flip prettyCtx True ) (take th ectx)
                                                  ++ map (flip prettyCtx False) (drop th ectx)))

-- reorganiser errors
prettyRE :: (ReorganizeError, [(SourceObject, SourcePos)]) -> Doc
prettyRE (msg,ps) = pretty msg <$>
                    indent' (vcat (map (\(so,p) -> context "-" <+> pretty so
                                               <+> context "(" <> pretty p <> context ")") ps))

prettyPrint :: Pretty a => (Doc -> Doc) -> [a] -> SimpleDoc
prettyPrint f = renderSmart 1.0 120 . f . vcat . map pretty


