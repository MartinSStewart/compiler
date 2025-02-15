module Optimize.Names exposing
    ( Tracker
    , apply
    , bind
    , fmap
    , generate
    , mapTraverse
    , pure
    , registerCtor
    , registerDebug
    , registerField
    , registerFieldDict
    , registerFieldList
    , registerGlobal
    , registerKernel
    , run
    , traverse
    )

import AST.Canonical as Can
import AST.Optimized as Opt
import Data.Index as Index
import Data.Map as Dict exposing (Dict)
import Data.Name as Name exposing (Name)
import Data.Set as EverySet exposing (EverySet)
import Elm.ModuleName as ModuleName
import Reporting.Annotation as A
import Utils.Main as Utils



-- GENERATOR


type Tracker a
    = Tracker
        (Int
         -> EverySet Opt.Global
         -> Dict Name Int
         -> TResult a
        )


type TResult a
    = TResult Int (EverySet Opt.Global) (Dict Name Int) a


run : Tracker a -> ( EverySet Opt.Global, Dict Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty of
        TResult _ deps fields value ->
            ( deps, fields, value )


generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields ->
            TResult (uid + 1) deps fields (Name.fromVarIndex uid)


registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \uid deps fields ->
            TResult uid (EverySet.insert Opt.compareGlobal (Opt.toKernelGlobal home) deps) fields value


registerGlobal : ModuleName.Canonical -> Name -> Tracker Opt.Expr
registerGlobal home name =
    Tracker <|
        \uid deps fields ->
            let
                global =
                    Opt.Global home name
            in
            TResult uid (EverySet.insert Opt.compareGlobal global deps) fields (Opt.VarGlobal global)


registerDebug : Name -> ModuleName.Canonical -> A.Region -> Tracker Opt.Expr
registerDebug name home region =
    Tracker <|
        \uid deps fields ->
            let
                global =
                    Opt.Global ModuleName.debug name
            in
            TResult uid (EverySet.insert Opt.compareGlobal global deps) fields (Opt.VarDebug name home region Nothing)


registerCtor : ModuleName.Canonical -> Name -> Index.ZeroBased -> Can.CtorOpts -> Tracker Opt.Expr
registerCtor home name index opts =
    Tracker <|
        \uid deps fields ->
            let
                global =
                    Opt.Global home name

                newDeps =
                    EverySet.insert Opt.compareGlobal global deps
            in
            case opts of
                Can.Normal ->
                    TResult uid newDeps fields (Opt.VarGlobal global)

                Can.Enum ->
                    TResult uid newDeps fields <|
                        case name of
                            "True" ->
                                if home == ModuleName.basics then
                                    Opt.Bool True

                                else
                                    Opt.VarEnum global index

                            "False" ->
                                if home == ModuleName.basics then
                                    Opt.Bool False

                                else
                                    Opt.VarEnum global index

                            _ ->
                                Opt.VarEnum global index

                Can.Unbox ->
                    TResult uid (EverySet.insert Opt.compareGlobal identity newDeps) fields (Opt.VarBox global)


identity : Opt.Global
identity =
    Opt.Global ModuleName.basics Name.identity_


registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields ->
            TResult uid d (Utils.mapInsertWith compare (+) name 1 fields) value


registerFieldDict : Dict Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \uid d fields ->
            TResult uid
                d
                (Utils.mapUnionWith compare (+) fields (Dict.map (\_ -> toOne) newFields))
                value


toOne : a -> Int
toOne _ =
    1


registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \uid deps fields ->
            TResult uid deps (List.foldr addOne fields names) value


addOne : Name -> Dict Name Int -> Dict Name Int
addOne name fields =
    Utils.mapInsertWith compare (+) name 1 fields



-- INSTANCES


fmap : (a -> b) -> Tracker a -> Tracker b
fmap func (Tracker kv) =
    Tracker <|
        \n d f ->
            case kv n d f of
                TResult n1 d1 f1 value ->
                    TResult n1 d1 f1 (func value)


pure : a -> Tracker a
pure value =
    Tracker (\n d f -> TResult n d f value)


apply : Tracker a -> Tracker (a -> b) -> Tracker b
apply (Tracker kv) (Tracker kf) =
    Tracker <|
        \n d f ->
            case kf n d f of
                TResult n1 d1 f1 func ->
                    case kv n1 d1 f1 of
                        TResult n2 d2 f2 value ->
                            TResult n2 d2 f2 (func value)


bind : (a -> Tracker b) -> Tracker a -> Tracker b
bind callback (Tracker k) =
    Tracker <|
        \n d f ->
            case k n d f of
                TResult n1 d1 f1 a ->
                    case callback a of
                        Tracker kb ->
                            kb n1 d1 f1


traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func =
    List.foldl (\a -> bind (\acc -> fmap (\b -> acc ++ [ b ]) (func a))) (pure [])


mapTraverse : (k -> k -> Order) -> (a -> Tracker b) -> Dict k a -> Tracker (Dict k b)
mapTraverse keyComparison func =
    Dict.foldl (\k a -> bind (\c -> fmap (\va -> Dict.insert keyComparison k va c) (func a))) (pure Dict.empty)
