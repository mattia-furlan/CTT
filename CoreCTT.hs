{-# LANGUAGE FlexibleInstances #-}

module CoreCTT where

import Data.List (intercalate,delete,deleteBy)
import Data.Maybe (fromJust)
import Data.Set (Set(..))
import Control.Monad.State

import Ident
import Interval

{- Syntax (terms/values) -}

data Term
    = Var Ident
    | Universe
    {- Abstraction -}
    | Abst Ident Term Term
    | App Term Term
    {- Sigma types -}
    | Sigma Ident Term Term
    | Pair Term Term
    | Fst Term
    | Snd Term
    {- Coproducts -}
    | Sum Term Term
    | InL Term
    | InR Term
    | Split Term Term Term Term
    {- Naturals -}
    | Nat
    | Zero
    | Succ Term
    | Ind Term Term Term Term
    {- Cubical -}
    | I | I0 | I1
    | Sys System
    | Partial DisjFormula Term
    | Restr System Term
    | Comp Term DisjFormula Term Term Term Term    -- type fam,phi,i0,u,base,i
    {-  For values only: -}
    | Closure Term Ctx   
    | Neutral Value Value          -- value,type
  deriving (Eq, Ord)

type Value = Term

newtype Program = Program [Toplevel]

data Toplevel = Definition Ident Term Term   -- Type-check and add to the context
              | Declaration Ident Term       -- Check type formation
              | Example Term                 -- Infer type and normalize 
  deriving (Eq, Ord)

isNumeral :: Term -> (Bool,Int)
isNumeral Zero     = (True,0)
isNumeral (Succ t) = (isNum,n + 1)
    where (isNum,n) = isNumeral t
isNumeral _ = (False,0)


-- Generates a new name starting from 'x' (maybe too inefficient - TODO)
newVar :: [Ident] -> Ident -> Ident
newVar used x
    | x == Ident "" =  Ident "" --TODO necessary?
    | x `elem` used = newVar used (Ident $ show x ++ "'")
    | otherwise     =  x

collectApps :: Term -> [Term] -> (Term,[Term])
collectApps t apps = case t of
    App t1 t2' -> collectApps t1 (t2' : apps)
    otherwise  -> (t,apps)

collectAbsts :: Term -> [(Ident,Term)] -> (Term,[(Ident,Term)])
collectAbsts t absts = case t of
    Abst s t e -> collectAbsts e ((s,t) : absts)
    otherwise -> (t,absts)

class SyntacticObject a where
    containsVar :: Ident -> a -> Bool
    containsVar s x = s `elem` (freeVars x)
    vars :: a -> [Ident]
    freeVars :: a -> [Ident]

instance SyntacticObject Ident where
    vars s = [s]
    freeVars s = [s]

instance SyntacticObject System where
    vars sys = concatMap vars (keys sys) ++ concatMap vars (elems sys)
    freeVars = vars

instance SyntacticObject Term where
    vars t = case t of
        Var s                 -> [s]
        Universe              -> []
        Abst s t e            -> vars t ++ vars e
        App fun arg           -> vars fun ++ vars arg
        Sigma s t e           -> vars t ++ vars e
        Pair t1 t2            -> vars t1 ++ vars t2
        Fst t                 -> vars t
        Snd t                 -> vars t
        Sum ty1 ty2           -> vars ty1 ++ vars ty2
        InL t1                -> vars t1
        InR t2                -> vars t2
        Split x ty f1 f2      -> vars x ++ vars ty ++ vars f1 ++ vars f2 
        Nat                   -> []
        Zero                  -> []
        Succ t                -> vars t
        Ind ty b s n          -> vars ty ++ vars b ++ vars s ++ vars n
        I                     -> []
        I0                    -> []
        I1                    -> []
        Sys sys               -> vars sys
        Partial phi t         -> vars phi ++ vars t
        Restr sys t           -> vars sys ++ vars t
        Comp fam phi i0 u b i -> vars fam ++ vars phi ++ vars i0 ++ vars u ++ vars b ++ vars i
        Closure t ctx         -> vars t ++ keys ctx
        Neutral v _           -> vars t
    freeVars t = case t of
        Var s                 -> [s]
        Universe              -> []
        Abst s t e            -> freeVars t ++ filter (/= s) (freeVars e)
        App fun arg           -> freeVars fun ++ freeVars arg
        Sigma s t e           -> freeVars t ++ filter (/= s) (freeVars e)
        Pair t1 t2            -> freeVars t1 ++ freeVars t2
        Fst t                 -> freeVars t
        Snd t                 -> freeVars t
        Sum ty1 ty2           -> freeVars ty1 ++ freeVars ty2
        InL t1                -> freeVars t1
        InR t2                -> freeVars t2
        Split x ty f1 f2      -> freeVars x ++ freeVars ty ++ freeVars f1 ++ freeVars f2 
        Nat                   -> []
        Zero                  -> []
        Succ t                -> freeVars t
        Ind ty b s n          -> freeVars ty ++ freeVars b ++ freeVars s ++ freeVars n
        I                     -> []
        I0                    -> []
        I1                    -> []
        Sys sys               -> freeVars sys
        Partial phi t         -> freeVars phi ++ freeVars t
        Restr sys t           -> freeVars sys ++ freeVars t
        Comp fam phi i0 u b i -> freeVars fam ++ freeVars phi ++ freeVars i0 ++ freeVars u ++ freeVars b ++ freeVars i
        Closure t ctx         -> freeVars t ++ keys ctx
        Neutral v _           -> freeVars v

instance SyntacticObject AtomicFormula where
    vars af = case af of
        Eq0 s        -> [s]
        Eq1 s        -> [s]
        Diag s1 s2   -> [s1,s2]
    freeVars = vars

instance SyntacticObject ConjFormula where
    vars (Conj cf) = concatMap vars cf
    freeVars = vars

instance SyntacticObject DisjFormula where
    vars (Disj df) = concatMap vars df
    freeVars = vars

checkTermShadowing :: [Ident] -> Term -> Bool
checkTermShadowing vars t = case t of
    Var s                 -> True
    Universe              -> True
    Abst (Ident "") t e   -> checkTermShadowing vars t && checkTermShadowing vars e
    Abst s t e            -> s `notElem` vars &&
        checkTermShadowing vars t && checkTermShadowing (if s == Ident "" then vars else s : vars) e 
    App fun arg           -> checkTermShadowing vars fun && checkTermShadowing vars arg
    Sigma s t e           -> s `notElem` vars &&
        checkTermShadowing vars t && checkTermShadowing (if s == Ident "" then vars else s : vars) e 
    Pair t1 t2            -> checkTermShadowing vars t1 && checkTermShadowing vars t2
    Fst t                 -> checkTermShadowing vars t
    Snd t                 -> checkTermShadowing vars t
    Sum ty1 ty2           -> checkTermShadowing vars ty1 && checkTermShadowing vars ty2
    InL t1                -> checkTermShadowing vars t1
    InR t2                -> checkTermShadowing vars t2
    Split x ty f1 f2      -> checkTermShadowing vars x && checkTermShadowing vars ty &&
        checkTermShadowing vars f1 && checkTermShadowing vars f2 
    Nat                   -> True
    Zero                  -> True
    Succ n                -> checkTermShadowing vars n
    Ind ty b s n          -> checkTermShadowing vars ty && checkTermShadowing vars b &&
        checkTermShadowing vars s && checkTermShadowing vars n
    I                     -> True
    I0                    -> True
    I1                    -> True
    Sys sys               -> all (checkTermShadowing vars) (elems sys)
    Partial phi t         -> checkTermShadowing vars t
    Restr sys t           -> all (checkTermShadowing vars) (elems sys) && checkTermShadowing vars t
    Comp fam phi i0 u b i -> checkTermShadowing vars fam && checkTermShadowing vars i0 &&
        checkTermShadowing vars u && checkTermShadowing vars b && checkTermShadowing vars i


{- Printing functions are in 'Eval.hs' -}

{- Contexts -}

type ErrorString = String

{- Generic association lists utilities -}

--lookup :: (Eq a) => a -> [(a, b)] -> Maybe b --already defined in the Prelude

--extend :: [(k,a)] -> k -> a -> [(k,a)]
--extend al s v = (s,v) : al

extend :: Ctx -> Ident -> CtxEntry -> Ctx
extend ctx s e = if s == Ident "" then ctx else (s,e) : ctx

keys :: [(k,a)] -> [k]
keys = map fst

elems :: [(k,a)] -> [a]
elems = map snd

mapElems :: (a -> b) -> [(k,a)] -> [(k,b)]
mapElems f = map (\(s,v) -> (s,f v))

at :: (Eq k) => [(k,a)] -> k -> a
al `at` s = fromJust (lookup s al)

{- Contexts -}

type Ctx = [(Ident,CtxEntry)]

data CtxEntry = Decl Term      -- Type
              | Def Term Term  -- Type and definition
              | Val Value      -- For `eval`
    deriving (Eq, Ord)

emptyCtx :: Ctx
emptyCtx = []

getBindings :: Ctx -> [(Ident,Value)]
getBindings ctx = map (\(s,Val v) -> (s,v))$ 
    filter (\(_,entry) -> case entry of Val _ -> True; _ -> False) ctx

instance SyntacticObject CtxEntry where
    vars entry = case entry of
        Decl t     -> vars t
        Def ty def -> vars ty ++ vars def
        Val _      -> [] --TODO
    freeVars entry = case entry of
        Decl t     -> freeVars t
        Def ty def -> freeVars ty ++ freeVars def
        Val _      -> [] --TODO

getLockedCtx :: [Ident] -> Ctx -> Ctx
getLockedCtx idents ctx = foldr getLockedCtx' ctx idents
    where
        getLockedCtx' :: Ident -> Ctx -> Ctx
        getLockedCtx' s ((s',Def ty def) : ctx) =
            if s == s' then (s,Decl ty) : ctx
                       else (s',Def ty def) : getLockedCtx' s ctx
        getLockedCtx' s ((s',Decl ty) : ctx) =
            (s',Decl ty) : getLockedCtx' s ctx
        getLockedCtx' s ctx = ctx

removeFromCtx :: Ctx -> Ident -> Ctx
removeFromCtx ctx s = if s `elem` (keys ctx) then
        let fall = map fst $ filter (\(_,entry) -> s `elem` (freeVars entry) ) ctx
            ctx' = filter (\(s',_) -> s /= s') ctx
        in foldl removeFromCtx ctx' fall
    else
        ctx


{- Cubical -}

type System = [(ConjFormula,Term)]

getSystemFormula :: System -> DisjFormula
getSystemFormula = Disj . map fst

getFormula :: Value -> DisjFormula
getFormula v = case v of
    Sys sys       -> getSystemFormula sys
    Partial phi v -> phi
    Restr sys v   -> getSystemFormula sys
    otherwise     -> fFalse

isPartial :: Value -> Bool
isPartial v = case v of
    Partial _ _ -> True
    otherwise   -> False

isRestr :: Value -> Bool
isRestr v = case v of
    Restr _ _   -> True
    otherwise   -> False

split :: Value -> (DisjFormula,Value)
split v = case v of
    Partial phi ty -> (phi,ty)
    Restr sys ty   -> (fTrue,ty)
    otherwise      -> (fTrue,v)

getMsg :: Bool -> String -> String
getMsg flag s = if flag then s else ""  

{- State monad for type-checking and evaluation -}

{-
type Env = (Ctx,DirEnv,[String])

type EnvState a = State Env a

ctx :: EnvState Ctx
ctx = do
    (ctx,dirs,logs) <- get
    return ctx

dirs :: EnvState DirEnv
dirs = do
    (ctx,dirs,logs) <- get
    return dirs

addlog :: String -> EnvState ()
addlog s = do
    (ctx,dirs,logs) <- get
    put (ctx,dirs,s : logs)
-}

