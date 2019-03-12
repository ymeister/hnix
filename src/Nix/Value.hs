{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# OPTIONS_GHC -Wno-missing-pattern-synonym-signatures #-}

module Nix.Value where

import           Control.Comonad
import           Control.Monad
-- import           Control.Monad.Catch
import           Control.Monad.Free
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Except
import qualified Data.Aeson as A
import           Data.Align
import           Data.Fix
import           Data.Functor.Classes
import qualified Data.HashMap.Lazy as M
import           Data.These
import           Data.Typeable (Typeable)
import           GHC.Generics
import           Lens.Family2
import           Lens.Family2.Stock
import           Lens.Family2.TH
import           Nix.Atoms
import           Nix.Expr.Types
import           Nix.Expr.Types.Annotated
-- import           Nix.Frames
import           Nix.String
import           Nix.Thunk
import           Nix.Utils

-- | An 'NValue' is the most reduced form of an 'NExpr' after evaluation is
--   completed. 's' is related to the type of errors that might occur during
--   construction or use of a value.
data NValueF a m r
    = NVConstantF NAtom
     -- | A string has a value and a context, which can be used to record what a
     -- string has been build from
    | NVStrF NixString
    | NVPathF FilePath
    | NVListF [r]
    | NVSetF (AttrSet r) (AttrSet SourcePos)
    | NVClosureF (Params ()) (m a -> m r)
      -- ^ A function is a closed set of parameters representing the "call
      --   signature", used at application time to check the type of arguments
      --   passed to the function. Since it supports default values which may
      --   depend on other values within the final argument set, this
      --   dependency is represented as a set of pending evaluations. The
      --   arguments are finally normalized into a set which is passed to the
      --   function.
      --
      --   Note that 'm r' is being used here because effectively a function
      --   and its set of default arguments is "never fully evaluated". This
      --   enforces in the type that it must be re-evaluated for each call.
    | NVBuiltinF String (m a -> m r)
      -- ^ A builtin function is itself already in normal form. Also, it may
      --   or may not choose to evaluate its argument in the production of a
      --   result.
    deriving (Generic, Typeable, Functor)

-- | An 'NValueNF' is a fully evaluated value in normal form. An 'NValue m' is
--   a value in head normal form, where only the "top layer" has been
--   evaluated. An action of type 'm (NValue m)' is a pending evualation that
--   has yet to be performed. An 'NThunk m' is either a pending evaluation, or
--   a value in head normal form. A 'NThunkSet' is a set of mappings from keys
--   to thunks.
--
--   The 'Free' structure is used here to represent the possibility that
--   cycles may appear during normalization.

comapNValueFArg :: Functor m => (b -> a) -> NValueF a m r -> NValueF b m r
comapNValueFArg f = \case
    NVConstantF a  -> NVConstantF a
    NVStrF s       -> NVStrF s
    NVPathF p      -> NVPathF p
    NVListF l      -> NVListF l
    NVSetF s p     -> NVSetF s p
    NVClosureF p g -> NVClosureF p (g . fmap f)
    NVBuiltinF s g -> NVBuiltinF s (g . fmap f)

newtype NValueNF m
    = NValueNF { _nValueNF :: Free (Compose (ValueContext m)
                                   (NValueF (NValueNF m) m)) (NValueNF m) }
    deriving (Generic, Typeable)

class (Monad m,
       Comonad (ValueContext m),
       Applicative (ValueContext m),
       Traversable (ValueContext m))
  => MonadDataContext (m :: * -> *) where
    type ThunkContext m :: * -> *
    type ValueContext m :: * -> *

newtype NValue m
    = NValue { _nValue :: Fix (Compose (ValueContext m)
                              (Compose (NValueF (NValue m) m)
                               (ThunkContext m))) }

type NThunk m
    = ThunkContext m (Fix (Compose (ValueContext m)
                           (Compose (NValueF (NValue m) m)
                            (ThunkContext m))))

type ValueSet m = AttrSet (NThunk m)

thunkEq :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
        => NThunk m -> NThunk m -> m Bool
thunkEq lt rt = force lt $ \lv -> force rt $ \rv ->
 let unsafePtrEq = case (lt, rt) of
         (thunkId -> lid, thunkId -> rid)
             | lid == rid -> return True
         _ -> valueEq lv rv
 in case (lv, rv) of
   (NVClosure _ _, NVClosure _ _) -> unsafePtrEq
   (NVList _, NVList _) -> unsafePtrEq
   (NVSet _ _, NVSet _ _) -> unsafePtrEq
   _ -> valueEq lv rv

weakenNValue :: forall m. (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
             => NValueNF m -> NValue m
weakenNValue (NValueNF v) = iter (phi . getCompose) (fmap weakenNValue v)
  where
    phi :: ValueContext m (NValueF (NValueNF m) m (NValue m)) -> NValue m
    phi = NValue . Fix . Compose
        . fmap (Compose . fmap wrapValue . comapNValueFArg removeEffects)

removeEffects :: forall m. (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
              => NValue m -> NValueNF m
removeEffects (NValue (Fix (Compose (fmap getCompose -> v)))) =
    NValueNF $ Free $ Compose $
        fmap (fmap (_nValueNF . dethunk) . comapNValueFArg weakenNValue) v

dethunk :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
        => NThunk m -> NValueNF m
dethunk t = query t opaque removeEffects

removeEffectsM :: forall m. (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
               => NValue m -> m (NValueNF m)
removeEffectsM (NValue (Fix (Compose (fmap getCompose -> v)))) = do
    x <- traverse (fmap (fmap _nValueNF) . go . comapNValueFArg weakenNValue) v
    pure $ NValueNF . Free . Compose $ x
  where
    go :: NValueF (NValueNF m) m (NThunk m)
       -> m (NValueF (NValueNF m) m (NValueNF m))
    go = \case
        NVConstantF a  -> pure $ NVConstantF a
        NVStrF s       -> pure $ NVStrF s
        NVPathF p      -> pure $ NVPathF p
        NVListF l      -> NVListF <$> traverse dethunkM l
        NVSetF s p     -> NVSetF <$> traverse dethunkM s <*> pure p
        NVClosureF p g -> pure $ NVClosureF p (dethunkM <=< g)
        NVBuiltinF s g -> pure $ NVBuiltinF s (dethunkM <=< g)

dethunkM :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
        => NThunk m -> m (NValueNF m)
dethunkM t = queryM t (pure opaque) removeEffectsM

opaque :: forall m. (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
       => NValueNF m
opaque = NValueNF $ Free $ Compose $ pure $ NVStrF @(NValueNF m) $
    principledMakeNixStringWithoutContext "<thunk>"

-- addProvenance :: (NValue m -> Provenance t (NValue m) m) -> NValue m -> NValue m
-- addProvenance f l@(NValue (NCited p v)) = NValue (NCited (f l : p) v)

pattern NVConstant x <- NValue (Fix (Compose (extract -> Compose (NVConstantF x))))

nvConstant x = NValue (Fix (Compose (pure (Compose (NVConstantF x)))))
-- nvConstantP p x = NValue (NCited [p] (NVConstantF x))

pattern NVStr ns <- NValue (Fix (Compose (extract -> Compose (NVStrF ns))))

nvStr ns = NValue (Fix (Compose (pure (Compose (NVStrF ns)))))
-- nvStrP p ns = NValue (NCited [p] (NVStrF ns))

pattern NVPath x <- NValue (Fix (Compose (extract -> Compose (NVPathF x))))

nvPath x = NValue (Fix (Compose (pure (Compose (NVPathF x)))))
-- nvPathP p x = NValue (NCited [p] (NVPathF x))

pattern NVList l <- NValue (Fix (Compose (extract -> Compose (NVListF l))))

nvList l = NValue (Fix (Compose (pure (Compose (NVListF l)))))
-- nvListP p l = NValue (NCited [p] (NVListF l))

pattern NVSet s x <- NValue (Fix (Compose (extract -> Compose (NVSetF s x))))

nvSet s x = NValue (Fix (Compose (pure (Compose (NVSetF s x)))))
-- nvSetP p s x = NValue (NCited [p] (NVSetF s x))

pattern NVClosure x f <- NValue (Fix (Compose (extract -> Compose (NVClosureF x f))))

nvClosure x f = NValue (Fix (Compose (pure (Compose (NVClosureF x f)))))
-- nvClosureP p x f = NValue (NCited [p] (NVClosureF x f))

pattern NVBuiltin name f <- NValue (Fix (Compose (extract -> Compose (NVBuiltinF name f))))

nvBuiltin name f = NValue (Fix (Compose (pure (Compose (NVBuiltinF name f)))))
-- nvBuiltinP p name f = NValue (NCited [p] (NVBuiltinF name f))

instance Show (NValueF (NValue m) m (Fix (NValueF (NValue m) m))) where
    showsPrec = flip go where
      go (NVConstantF atom)  = showsCon1 "NVConstant" atom
      go (NVStrF ns)         = showsCon1 "NVStr"      (hackyStringIgnoreContext ns)
      go (NVListF     lst)   = showsCon1 "NVList"     lst
      go (NVSetF attrs _)    = showsCon1 "NVSet"      attrs
      go (NVClosureF p _)    = showsCon1 "NVClosure"  p
      go (NVPathF p)         = showsCon1 "NVPath"     p
      go (NVBuiltinF name _) = showsCon1 "NVBuiltin"  name

      showsCon1 :: Show a => String -> a -> Int -> String -> String
      showsCon1 con a d =
          showParen (d > 10) $ showString (con ++ " ") . showsPrec 11 a
{-
      showsCon2 :: (Show a, Show b)
                => String -> a -> b -> Int -> String -> String
      showsCon2 con a b d =
          showParen (d > 10)
              $ showString (con ++ " ")
              . showsPrec 11 a
              . showString " "
              . showsPrec 11 b
-}

{-
instance Eq (NValue m) where
    NVConstant (NFloat x) == NVConstant (NInt y)   = x == fromInteger y
    NVConstant (NInt x)   == NVConstant (NFloat y) = fromInteger x == y
    NVConstant (NInt x)   == NVConstant (NInt y)   = x == y
    NVConstant (NFloat x) == NVConstant (NFloat y) = x == y
    NVStr x   == NVStr y   = hackyStringIgnoreContext x == hackyStringIgnoreContext y
    NVPath x  == NVPath y  = x == y
    _         == _         = False

instance Ord (NValue m) where
    NVConstant (NFloat x) <= NVConstant (NInt y)   = x <= fromInteger y
    NVConstant (NInt x)   <= NVConstant (NFloat y) = fromInteger x <= y
    NVConstant (NInt x)   <= NVConstant (NInt y)   = x <= y
    NVConstant (NFloat x) <= NVConstant (NFloat y) = x <= y
    NVStr x   <= NVStr y   = hackyStringIgnoreContext x <= hackyStringIgnoreContext y
    NVPath x  <= NVPath y  = x <= y
    _         <= _         = False

checkComparable :: (Framed e m, Typeable m) => NValue m -> NValue m -> m ()
checkComparable x y = case (x, y) of
    (NVConstant (NFloat _), NVConstant (NInt _))   -> pure ()
    (NVConstant (NInt _),   NVConstant (NFloat _)) -> pure ()
    (NVConstant (NInt _),   NVConstant (NInt _))   -> pure ()
    (NVConstant (NFloat _), NVConstant (NFloat _)) -> pure ()
    (NVStr _, NVStr _)     -> pure ()
    (NVPath _, NVPath _)   -> pure ()
    _ -> throwError $ Comparison x y
-}

builtin :: forall m. (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
        => String -> (m (NValue m) -> m (NValue m)) -> m (NValue m)
builtin name f = return $ nvBuiltin name $ thunk . f

builtin2 :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
         => String -> (m (NValue m) -> m (NValue m) -> m (NValue m))
         -> m (NValue m)
builtin2 name f = builtin name (builtin name . f)

builtin3 :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
         => String
         -> (m (NValue m) -> m (NValue m) -> m (NValue m) -> m (NValue m))
         -> m (NValue m)
builtin3 name f =
    builtin name $ \a -> builtin name $ \b -> builtin name $ \c -> f a b c

isClosureNF :: MonadDataContext m => NValueNF m -> Bool
isClosureNF (NValueNF (Free (Compose (extract -> NVClosureF {})))) = True
isClosureNF _ = False

-- | Checks whether two containers are equal, using the given item equality
--   predicate. If there are any item slots that don't match between the two
--   containers, the result will be False.
alignEqM
    :: (Align f, Traversable f, Monad m)
    => (a -> b -> m Bool)
    -> f a
    -> f b
    -> m Bool
alignEqM eq fa fb = fmap (either (const False) (const True)) $ runExceptT $ do
    pairs <- forM (Data.Align.align fa fb) $ \case
        These a b -> return (a, b)
        _ -> throwE ()
    forM_ pairs $ \(a, b) -> guard =<< lift (eq a b)

isDerivation :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
             => AttrSet (NThunk m) -> m Bool
isDerivation m = case M.lookup "type" m of
    Nothing -> pure False
    Just t -> force t $ \case
      -- We should probably really make sure the context is empty here but the
      -- C++ implementation ignores it.
      NVStr s -> pure $ principledStringIgnoreContext s == "derivation"
      _ -> pure False

valueEq :: (MonadThunk (NValue m) (NThunk m) m, MonadDataContext m)
        => NValue m -> NValue m -> m Bool
valueEq = curry $ \case
    (NVConstant lc, NVConstant rc) -> pure $ lc == rc
    (NVStr ls, NVStr rs) ->
        pure $ principledStringIgnoreContext ls
            == principledStringIgnoreContext rs
    (NVList ls, NVList rs) -> alignEqM thunkEq ls rs
    (NVSet lm _, NVSet rm _) -> do
        let compareAttrs = alignEqM thunkEq lm rm
        isDerivation lm >>= \case
            True -> isDerivation rm >>= \case
                True | Just lp <- M.lookup "outPath" lm
                     , Just rp <- M.lookup "outPath" rm
                       -> thunkEq lp rp
                _ -> compareAttrs
            _ -> compareAttrs
    (NVPath lp, NVPath rp) -> pure $ lp == rp
    _ -> pure False

data TStringContext = NoContext | HasContext
  deriving Show

data ValueType
    = TInt
    | TFloat
    | TBool
    | TNull
    | TString TStringContext
    | TList
    | TSet
    | TClosure
    | TPath
    | TBuiltin
    deriving Show

valueType :: NValueF a m r -> ValueType
valueType = \case
    NVConstantF a -> case a of
        NInt _    -> TInt
        NFloat _  -> TFloat
        NBool _   -> TBool
        NNull     -> TNull
    NVStrF ns | stringHasContext ns ->  TString HasContext
              | otherwise -> TString NoContext
    NVListF {}    -> TList
    NVSetF {}     -> TSet
    NVClosureF {} -> TClosure
    NVPathF {}    -> TPath
    NVBuiltinF {} -> TBuiltin

describeValue :: ValueType -> String
describeValue = \case
    TInt               -> "an integer"
    TFloat             -> "a float"
    TBool              -> "a boolean"
    TNull              -> "a null"
    TString NoContext  -> "a string"
    TString HasContext -> "a string with context"
    TList              -> "a list"
    TSet               -> "an attr set"
    TClosure           -> "a function"
    TPath              -> "a path"
    TBuiltin           -> "a builtin function"

instance MonadDataContext m => Show (NValue m) where
    show = describeValue
        . valueType
        . getCompose
        . extract
        . getCompose
        . unFix
        . _nValue

instance Show (NValueF (NValue m) m
               (f (Fix (Compose g (Compose (NValueF (NValue m) m) f))))) where
    show = describeValue . valueType

instance Show (NValueF (NValueNF m) m r) where
    show = describeValue . valueType

-- instance MonadDataContext m => Show (NValue m) where
--     show (NValue (Fix (Compose (extract -> Compose v)))) = show v

instance MonadDataContext m => Show (NValueNF m) where
    show (NValueNF (Pure v)) = show v
    show (NValueNF (Free (Compose (extract -> v)))) = show v

instance Eq1 (NValueF (NValue m) m) where
    liftEq _  (NVConstantF x) (NVConstantF y) = x == y
    liftEq _  (NVStrF x)      (NVStrF y)      = x == y
    liftEq eq (NVListF x)     (NVListF y)     = liftEq eq x y
    liftEq eq (NVSetF x _)    (NVSetF y _)    = liftEq eq x y
    liftEq _  (NVPathF x)     (NVPathF y)     = x == y
    liftEq _ _ _ = False

instance Show1 (NValueF (NValue m) m) where
    liftShowsPrec sp sl p = \case
        NVConstantF atom  -> showsUnaryWith showsPrec "NVConstantF" p atom
        NVStrF ns         -> showsUnaryWith showsPrec "NVStrF"      p (hackyStringIgnoreContext ns)
        NVListF     lst   -> showsUnaryWith (liftShowsPrec sp sl) "NVListF" p lst
        NVSetF attrs _    -> showsUnaryWith (liftShowsPrec sp sl) "NVSetF"  p attrs
        NVClosureF c _    -> showsUnaryWith showsPrec "NVClosureF"  p c
        NVPathF path      -> showsUnaryWith showsPrec "NVPathF"     p path
        NVBuiltinF name _ -> showsUnaryWith showsPrec "NVBuiltinF"  p name

data ValueFrame m
    = ForcingThunk
    | ConcerningValue (NValue m)
    | Comparison (NValue m) (NValue m)
    | Addition (NValue m) (NValue m)
    | Multiplication (NValue m) (NValue m)
    | Division (NValue m) (NValue m)
    | Coercion ValueType ValueType
    | CoercionToJson (NValue m)
    | CoercionFromJson A.Value
    | ExpectationNF ValueType (NValueNF m)
    | Expectation ValueType (NValue m)
--     deriving (Show, Typeable)

-- instance Typeable m => Exception (ValueFrame m)

$(makeTraversals ''NValueF)
$(makeLenses ''NValue)

key :: (Applicative f, MonadDataContext m)
    => VarName -> LensLike' f (NValue m) (Maybe (NThunk m))
key k = nValue._unFix._getCompose.traverse._getCompose._NVSetF._1.hashAt k
