{-
  A basic parser and interpreter for a cut-down version of Prolog

  Author: Ken Friis Larsen <kflarsen@diku.dk>
-}

import Text.ParserCombinators.Parsec
import Data.List (nub)
import Control.Monad(ap,liftM)

----------------------------------------------------------------------
-- Abstract Syntax Tree
----------------------------------------------------------------------

type Goal = [Term]
type Program = (Clauses, Funcs)
type Clauses = [Clause]
type Clause = (Term, Terms) -- head and body
type Func = (Ident, ([Variable], Term)) -- name and (arguments and body)
type Funcs = [Func]
data Term = Var Variable
          | Val Int
          | Comp Ident [Term]
            deriving (Eq, Show, Read)
type Terms = [Term]
type Ident = String
type Variable = String

----------------------------------------------------------------------
-- Parser
----------------------------------------------------------------------
comment = do char '%' 
             manyTill anyChar (try newline)
             return ()
          
spacesOrComments = skipMany ((space >> return()) <|> comment)

csymb c = (try(spacesOrComments >> char c) >> spacesOrComments)
symb s = (try(spacesOrComments >> string s) >> spacesOrComments)

goal :: Parser Goal
goal = do symb "?-"
          ts <- terms
          csymb '.'
          return ts

program :: Parser Program
program = do spacesOrComments
             mixed <- many1 clauseOrFunction
             return ([ c | Left c <- mixed], [ f | Right f <- mixed]) 



clauseOrFunction :: Parser (Either Clause Func)
clauseOrFunction =  (try clause >>= return . Left)
                <|> (try function >>= return . Right)

clause :: Parser Clause
clause = do t <- term
            body <- option []
                    (symb ":-" >> terms)
            csymb '.'
            return (t, body)
            
function :: Parser Func
function = do name <- ident
              args <- parens $ sepBy1 variable (csymb ',')
              body <- csymb ':' >> term
              csymb '.'
              return (name, (args, body))

term :: Parser Term
term =  (variable >>= return . Var)
    <|> literal
    <|> (list     <?> "list term")
    <|> intval

terms :: Parser Terms
terms = sepBy1 term (csymb ',')

literal :: Parser Term
literal = do id <- ident
             option (Comp id [])
                    (parens terms >>= return . Comp id)

parens :: Parser p -> Parser p
parens p = between (csymb '(') (csymb ')') p

list :: Parser Term
list = between (csymb '[') (csymb ']')
               (option emptyListTerm listTerms)

listTerms :: Parser Term
listTerms =
    do heads <- terms
       tail <- option emptyListTerm
                      (csymb '|' >> term)
       return (foldr cons tail heads)

emptyListTerm :: Term
emptyListTerm = Comp "[]" []

cons :: Term -> Term -> Term
cons h t = Comp "." [h,t]

ident :: Parser Ident
ident = (do c <- lower
            cs <- many (alphaNum <|> char '_')
            return (c:cs)) <?> "identifier"

variable :: Parser String
variable = (do c <- upper <|> char '_'
               cs <- many (alphaNum <|> char '_')
               return (c:cs)) <?> "variable"

intval :: Parser Term
intval = (do digits <- many1 digit
             return $ Val $ read digits) <?> "integer"

----------------------------------------------------------------------
-- Interpreter
----------------------------------------------------------------------

type Unifier = [(Variable, Term)]

compose u1 u2 = (map (\(v, t) -> (v, subs u2 t)) u1) ++ u2

occursIn :: Variable -> Term -> Bool
occursIn v (Var x)     = v == x
occursIn v (Comp _ ms) = any (occursIn v) ms
occursIn v (Val _)     = False

subs :: Unifier -> Term -> Term
subs u t@(Var x)   = maybe t id (lookup x u)
subs u (Comp n ts) = Comp n (map (subs u) ts)
subs u t@(Val _)   = t

unify :: Term -> Term -> Maybe Unifier
unify (Var x) (Var y) | x == y         = return []
unify (Var x) t | not(x `occursIn` t)  = return [(x, t)]
unify t v@(Var _)                      = unify v t
unify (Comp m ms) (Comp n ns) | m == n = unifyList ms ns
unify (Val x) (Val y) | x == y         = return []
unify _ _                              = Nothing

unifyList (t : ts) (r : rs) =
    do u1 <- unify t r
       u2 <- unifyList (map (subs u1) ts) (map (subs u1) rs)
       return $ u1 `compose` u2
unifyList [] [] = Just []
unifyList _ _   = Nothing

variables ts = nub $ varsList ts
    where vars (Var x) = [x]
          vars (Comp _ ts) = varsList ts
          vars (Val _) = []
          varsList ts = [ v | t <- ts, v <- vars t]

freshen bound (tc, tb) = (subs sub tc, map (subs sub) tb)
    where vars = variables(tc : tb)
          sub = [ (v, Var $ nextVar 0 v) | v <- vars, v `elem` bound]
          nextVar i v = let v' = "_" ++ show i ++ "_" ++ v in
                        if v' `elem` bound then nextVar (i+1) v
                        else v'

-- | Evaluate a grounded arithmetic term. That is, a term without variables
eval :: Program -> Term -> Int
eval prog (Var _) = error "Non-instantiated arithmetic term"
eval prog (Val n) = n
eval prog (Comp "plus" [t1, t2]) =
  let n1 = eval prog t1
      n2 = eval prog t2
  in n1 + n2
eval prog@(_, functions) (Comp f args) | Just (vars, body) <- lookup f functions = 
  eval prog (subs (zip vars args) body)


evalIs :: Program -> Term -> Unifier
evalIs prog (Comp "is" [Var x, t]) = [(x, Val $! eval prog t)]

evalCond :: Program -> Term -> Bool
evalCond prog (Comp "lt" [t1, t2]) = eval prog t1 < eval prog t2
evalCond prog (Comp n args) = if n `elem` conditionComps then error $ "Wrong number of arguments for " ++ n 
                              else error $ "Unknown operator " ++ n

conditionComps = ["lt"]
isCond t@(Comp n _) = n `elem` conditionComps
isCond _ = False

symbolicCond t | isCond t = not $ null $ variables [t]
symbolicCond _ = False

nonSymbolicCond t = isCond t && (not $ symbolicCond t)

normalizeGoal :: Program -> Goal -> Maybe Goal
normalizeGoal prog (t1@(Comp "is" _) : rest) = Just$ map (subs $ evalIs prog t1) rest
normalizeGoal prog (t1 : rest) | nonSymbolicCond t1 = if evalCond prog t1 then Just rest 
                                                      else Just []
normalizeGoal prog g@(t1 : _) | symbolicCond t1 = Just $ n : symb ++ non  
  where 
    (n : non, symb) = symbolicPrefix g
    symbolicPrefix (t : rest) | symbolicCond t = let (non, symb) = symbolicPrefix rest
                                                 in  (non, t : symb)
    symbolicPrefix nonsymb = (nonsymb, [])
normalizeGoal _ _ = Nothing

type Solution = ([(Variable, Term)], Terms)
data SearchTree = Solution Solution
                | Node Goal [SearchTree]
                  deriving (Eq, Show, Read)

-- Uses the List monad for backtracking
solve :: Program -> Goal -> [SearchTree]
solve _ g@(r : conds) | isReportGoal r =  return $ Solution $ getSolution g
solve prog@(clauses,_) g@(t1 : ts) = return $ Node g trees
    where trees =
            case normalizeGoal prog g of
              Just [] -> []
              Just ng -> solve prog ng
              Nothing -> do c <- clauses
                            let (tc, tsc) = freshen (variables g) c
                            case unify tc t1 of
                              Just u -> do
                                let g' = map (subs u) $ tsc ++ ts
                                solve prog g'
                              Nothing -> []
--solve _ _ = []

makeReportGoal goal = [Comp "_report" reportVars]
    where reportVars = map (\ v -> Comp "=" [Comp v [], Var v]) vars
          vars = variables goal

isReportGoal (Comp "_report" _) = True
isReportGoal _                  = False

getSolution ((Comp "_report" args) : conds) = (sol, conds)
    where sol = map (\ (Comp "=" [Comp v [], t]) -> (v, t)) args

-- Use the trick of inserting an extra reporting goal
makeReportTree prog goal = Node goal $ solve prog (goal ++ makeReportGoal goal)


----------------------------------------------------------------------
-- Traveral of Search Trees
----------------------------------------------------------------------

-- Depth first
dfs :: SearchTree -> [Solution]
dfs (Solution sols) = [sols]
dfs (Node g st) = [ s | t <- st, s <- dfs t]

-- Breath first
bfs :: SearchTree -> [Solution]
bfs t = trav [t]
    where trav [] = []
          trav ((Solution x) : q) = x : trav q
          trav ((Node _ st)  : q) = trav (q ++ st)


----------------------------------------------------------------------
-- Testing
----------------------------------------------------------------------

test filename goalString search =
    do Right p <- parseFromFile program filename
       let Right g = parse goal "<string>" goalString
       let t = makeReportTree p g
       return $ search t

tree filename goalString =
    do Right p <- parseFromFile program filename
       let Right g = parse goal "<string>" goalString
       let t = makeReportTree p g
       return $ t


siblings = test "siblings.pl" "?- sibling(homer, X)."
siblingsDFS = siblings dfs
siblingsBFS = siblings bfs


nats = test "nats.pl" "?- natlist(X)."
natsDFS = liftM (take 10) $ nats dfs
natsBFS = liftM (take 10) $ nats bfs

