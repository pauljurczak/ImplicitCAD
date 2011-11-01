-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Released under the GNU GPL, see LICENSE

-- We'd like to parse openscad code, with some improvements, for backwards compatability.

module Graphics.Implicit.ExtOpenScad where

import Prelude hiding (lookup)
import Graphics.Implicit.Definitions
import Data.Map hiding (map)
import Text.ParserCombinators.Parsec 
import Text.ParserCombinators.Parsec.Expr
import Control.Monad (liftM)

type VariableLookup = Map String OpenscadObj

data OpenscadObj = OUndefined 
		 | OBool Bool 
		 | ONum ℝ
		 | OList [OpenscadObj]
		 | OString String
		 | OFunc ( OpenscadObj -> OpenscadObj ) 

instance Show OpenscadObj where
	show OUndefined = "Undefined"
	show (OBool b) = show b
	show (ONum n) = show n
	show (OList l) = show l
	show (OString s) = show s
	show (OFunc f) = "<function>"

numericOFunc f = OFunc $ \oObj -> case oObj of
	ONum n -> ONum $ f n
	_ -> OUndefined

data Computation = 
	ControlStructure ( VariableLookup -> [Computation] -> ([Obj2], [Obj3], VariableLookup) ) [Computation]
	| Assignment (VariableLookup -> VariableLookup)
	| Object2 (VariableLookup -> Obj2)
	| Object3 (VariableLookup -> Obj3)
	| Include String

variableSymb = many1 (noneOf " ,|[]{}()*&^%$#@!~`'\"\\/;:.,<>?") <?> "variable"

variable :: GenParser Char st (VariableLookup -> OpenscadObj)
variable = liftM (\varstr -> \varlookup -> case lookup varstr varlookup of
			Nothing -> OUndefined
			Just a -> a )
		variableSymb
	
			

literal :: GenParser Char st (VariableLookup -> OpenscadObj)
literal = 
	try ( (string "true" >> return (\map -> OBool True) )
		<|> (string "false" >> return (\map -> OBool False) )
		<?> "boolean" )
	<|> try ( try (do
			a <- (many1 digit);
			char '.';
			b <- (many digit);
			return ( \map -> ONum ( read (a ++ "." ++ b) :: ℝ) );
		) <|>  (do
			a <- (many1 digit);
			return ( \map -> ONum ( read a :: ℝ) );
		) <?> "number" )
	<|> try ( ( do
		string "\"";
		strlit <- many $ noneOf "\"\n";
		string "\"";
		return $ \map -> OString $ strlit;
	) <?> "string" )
	<?> "literal"

-- space = oneOf " \t\n"

-- We represent the priority or 'fixity' of different types of expressions
-- by the Int argument

expression :: Int -> GenParser Char st (VariableLookup -> OpenscadObj)
expression 10 = (try literal) <|> (try variable )
	<|> ((do
		string "(";
		many space;
		expr <- expression 0;
		many space;
		string ")";
		return expr;
	) <?> "bracketed expression" )
	<|> ( ( do
		string "[";
		many space;
		exprs <- sepBy (expression 0) (many space >> char ',' >> many space);
		many space;
		string "]";
		return $ \varlookup -> OList (map ($varlookup) exprs )
	) <?> "vector/list" )
expression 9 = ( try( do 
		f <- expression 10;
		string "(";
		many space;
		arg <- expression 0;
		many space;
		string ")";
		return $ \varlookup ->
			case f varlookup of
				OFunc actual_func -> actual_func (arg varlookup)
				_ -> OUndefined
	) <?> "function appliation" )
	<|> try (expression 10)
expression n@8 = try (( do 
		a <- expression (n+1);
		string "^";
		b <- expression n;
		return $ \varlookup -> case (a varlookup, b varlookup) of
			(ONum na, ONum nb) -> ONum (na ** nb)
			_ -> OUndefined
	) <?> "exponentiation")
	<|> try (expression $ n+1)
expression n@7 =  try (expression $ n+1)
expression n@6 = 
	let 
		mult (ONum a) (ONum b) = ONum (a*b)
		mult (ONum a) (OList b) = OList (map (mult (ONum a)) b)
		mult (OList a) (ONum b) = OList (map (mult (ONum b)) a)
		mult _ _ = OUndefined

		div  (ONum a) (ONum b) = ONum (a/b)
		div (OList a) (ONum b) = OList (map (\x -> div x (ONum b)) a)
		div _ _ = OUndefined
	in try (( do 
		exprs <- sepBy1 (sepBy (expression $ n+1) (char '/')) (char '*')
		return $ \varlookup -> foldl1 mult $ map ( (foldl1 div) . (map ($varlookup) ) ) exprs;
	) <?> "multiplication/division")
	<|>try (expression $ n+1)
expression n@5 =
	let 
		append (OList a) (OList b) = OList $ a++b
		append (OString a) (OString b) = OString $ a++b
		append _ _ = OUndefined
	in try (( do 
		exprs <- sepBy1 (expression $ n+1) (string "++")
		return $ \varlookup -> foldl1 append $ map ($varlookup) exprs;
	) <?> "append") 
	<|>try (expression $ n+1)

expression n@4 =
	let 
		add (ONum a) (ONum b) = ONum (a+b)
		add (OList a) (OList b) = OList $ zipWith add a b
		add _ _ = OUndefined

		sub (ONum a) (ONum b) = ONum (a-b)
		sub (OList a) (OList b) = OList $ zipWith sub a b
		sub _ _ = OUndefined
	in try (( do 
		exprs <- sepBy1 (sepBy (expression $ n+1) (char '-')) (char '+')
		return $ \varlookup -> foldl1 add $ map ( (foldl1 sub) . (map ($varlookup) ) ) exprs;
	) <?> "addition/subtraction")
	<|>try (expression $ n+1)
expression n@3 = try (expression $ n+1)
expression n@2 = try (expression $ n+1)
expression n@1 = try (expression $ n+1)
expression n@0 = try (expression $ n+1)



testParse str = case parse (expression 0) ""  str of
		Right res -> show $ res 
			(fromList [("sin", numericOFunc sin)] )
		Left  err -> show err


assigmentStatement = do
	var <- variableSymb
	many space
	char '='
	many space
	val <- expression 0
	return $ Assignment (\varlookup -> insert var (val varlookup) varlookup)

{-ifStatement = do
	string "if"
	many space
	char '('
	condition <- expression 0
	char ')'
	many space
	trueCase <- computationStatement-}
	

computationStatement = assigmentStatement
