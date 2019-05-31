module Cogent.PrettifyLexer where
-- currently not in lexer:
--  :<
--  the < == thing


-- changes:
-- doc, // and /// instead of @ and @@
-- type app, @ instead of []
-- got rid of $
-- composition, |> and <| instead of "o"

-- TODO:
-- indexing, []
-- new syntax for lambda
-- let success error branch
-- Quantifier
-- something with error handling (replacing the original |>)
-- track source locations

import Data.Char(isSpace, isAlpha, isDigit)
import qualified Data.Map as M

data SourcePos
    = Pos { col :: Int
          , line :: Int
          , file :: FilePath
          }
        deriving (Show)

data Token
    = Kwd Keyword
    | Plus | Minus | Times | Divide | Modulo
    | Land | Lor
    | Geq | Leq | Gt | Lt | Eq | Neq
    | Band | Bor | Bxor | Lshift | Rshift
    | Col | Define | Bar | Bang
    | Dot | Ddot | Underscore | Hash 
    | Unbox | Typeapp
    | Langle | Rangle | Lparen | Rparen | Lbracket | Rbracket
    | Llikely | Likely | MLikely
    | Number Int
    deriving(Show)

data Keyword 
    = Let | In | Type | Include | All | Take | Put
    | Inline | Upcast | Repr | Variant | Record | At
    | If | Then | Else | Not | Complement | And 
    deriving(Show)

symTokens :: M.Map String Token
symTokens = M.fromList 
            [ (".&.", Band)
            , (".|.", Bor)
            , (".^.", Bxor)
            , ("&&", Land)
            , ("||", Lor)
            , (">=", Geq)
            , ("<=", Leq)
            , ("==", Eq)
            , ("/=", Neq)
            , ("<<", Lshift)
            , (">>", Rshift)
            , ("..", Ddot)
            , ("->", Likely)
            , ("=>", MLikely)
            , ("~>", Llikely)
            , ("+", Plus)
            , ("-", Minus)
            , ("*", Times)
            , ("/", Divide)
            , ("%", Modulo)
            , (":", Col)
            , ("=", Define)
            , ("!", Bang)
            , ("|", Bar)
            , (".", Dot)
            , ("_", Underscore)
            , ("#", Hash)
            , ("@", Typeapp)
            , ("<", Langle)
            , (">", Rangle)
            , ("(", Lparen)
            , (")", Rparen)
            , ("[", Lbracket)
            , ("]", Rbracket)
            ]

preprocess :: SourcePos -> String -> [(Char, SourcePos)]
preprocess p [] = []
preprocess p ('\n':cs) = ('\n',p):preprocess (p {col = 0, line = line p + 1}) cs
preprocess p (c:cs) = (c,p):preprocess (p {col = col p + 1}) cs
    
lexer :: [(Char, SourcePos)] -> [(Token, SourcePos)]
lexer [] = []
lexer (c:cs) | isSpace (fst c) = lexer cs
lexer cs     | Just t <- M.lookup (take 3 (map fst cs)) symTokens 
                = (t, snd(head cs)):lexer (drop 3 cs)
lexer cs     | Just t <- M.lookup (take 2 (map fst cs)) symTokens 
                = (t, snd(head cs)):lexer (drop 2 cs)
lexer cs     | Just t <- M.lookup (take 1 (map fst cs)) symTokens 
                = (t, snd(head cs)):lexer (drop 1 cs)

lexer (c:cs) | isAlpha (fst c) = let
    (word, rest) = span (isAlpha . fst) (c:cs)
    in (toToken (map fst word), snd c) : lexer rest
    where
        toToken :: String -> Token
        toToken "let" = Kwd Let
        toToken "in" = Kwd In
        toToken "type" = Kwd Type
        toToken "include" = Kwd Include
        toToken "all" = Kwd All
        toToken "take" = Kwd Take
        toToken "put" = Kwd Put
        toToken "inline" = Kwd Inline
        toToken "upcast" = Kwd Upcast
        toToken "repr" = Kwd Repr
        toToken "variant" = Kwd Variant
        toToken "record" = Kwd Record
        toToken "at" = Kwd At
        toToken "if" = Kwd If
        toToken "then" = Kwd Then
        toToken "else" = Kwd Else
        toToken "not" = Kwd Not
        toToken "complement" = Kwd Complement
        toToken "and" = Kwd And

lexer (c:cs) | isDigit (fst c) = let
    (numStr, rest) = span (isDigit . fst) (c:cs)
    in (Number (read (map fst numStr)), snd c): lexer rest

lexer _ = []

lexFile :: FilePath -> IO [(Token, SourcePos)]
lexFile fp = do 
    contents <- readFile fp
    pure (lexer (preprocess initialSourcePos contents))
  where
    initialSourcePos = Pos 0 0 fp