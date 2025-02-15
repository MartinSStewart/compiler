module Canonicalize.Environment exposing
    ( Binop(..)
    , Ctor(..)
    , Env
    , Exposed
    , Info(..)
    , Qualified
    , Type(..)
    , Var(..)
    , addLocals
    , findBinop
    , findCtor
    , findCtorQual
    , findType
    , findTypeQual
    , mergeInfo
    )

import AST.Canonical as Can
import AST.Utils.Binop as Binop
import Data.Index as Index
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Data.OneOrMore as OneOrMore
import Data.Set as EverySet
import Elm.ModuleName exposing (Canonical)
import Maybe exposing (Maybe(..))
import Reporting.Annotation as A
import Reporting.Error.Canonicalize as Error
import Reporting.Result as R



-- RESULT


type alias EResult i w a =
    R.RResult i w Error.Error a



-- ENVIRONMENT


type alias Env =
    { home : Canonical
    , vars : Dict Name.Name Var
    , types : Exposed Type
    , ctors : Exposed Ctor
    , binops : Exposed Binop
    , q_vars : Qualified Can.Annotation
    , q_types : Qualified Type
    , q_ctors : Qualified Ctor
    }


type alias Exposed a =
    Dict Name.Name (Info a)


type alias Qualified a =
    Dict Name.Name (Dict Name.Name (Info a))



-- INFO


type Info a
    = Specific Canonical a
    | Ambiguous Canonical (OneOrMore.OneOrMore Canonical)


mergeInfo : Info a -> Info a -> Info a
mergeInfo info1 info2 =
    case info1 of
        Specific h1 _ ->
            case info2 of
                Specific h2 _ ->
                    if h1 == h2 then
                        info1

                    else
                        Ambiguous h1 (OneOrMore.one h2)

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more (OneOrMore.one h2) hs2)

        Ambiguous h1 hs1 ->
            case info2 of
                Specific h2 _ ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.one h2))

                Ambiguous h2 hs2 ->
                    Ambiguous h1 (OneOrMore.more hs1 (OneOrMore.more (OneOrMore.one h2) hs2))



-- VARIABLES


type Var
    = Local A.Region
    | TopLevel A.Region
    | Foreign Canonical Can.Annotation
    | Foreigns Canonical (OneOrMore.OneOrMore Canonical)



-- TYPES


type Type
    = Alias Int Canonical (List Name.Name) Can.Type
    | Union Int Canonical



-- CTORS


type Ctor
    = RecordCtor Canonical (List Name.Name) Can.Type
    | Ctor Canonical Name.Name Can.Union Index.ZeroBased (List Can.Type)



-- BINOPS


type Binop
    = Binop Name.Name Canonical Name.Name Can.Annotation Binop.Associativity Binop.Precedence



-- VARIABLE -- ADD LOCALS


addLocals : Dict Name.Name A.Region -> Env -> EResult i w Env
addLocals names env =
    R.fmap (\newVars -> { env | vars = newVars })
        (Dict.merge (\name region -> R.fmap (Dict.insert compare name (addLocalLeft name region)))
            (\name region var acc ->
                addLocalBoth name region var
                    |> R.bind (\var_ -> R.fmap (Dict.insert compare name var_) acc)
            )
            (\name var -> R.fmap (Dict.insert compare name var))
            names
            env.vars
            (R.ok Dict.empty)
        )


addLocalLeft : Name.Name -> A.Region -> Var
addLocalLeft _ region =
    Local region


addLocalBoth : Name.Name -> A.Region -> Var -> EResult i w Var
addLocalBoth name region var =
    case var of
        Foreign _ _ ->
            R.ok (Local region)

        Foreigns _ _ ->
            R.ok (Local region)

        Local parentRegion ->
            R.throw (Error.Shadowing name parentRegion region)

        TopLevel parentRegion ->
            R.throw (Error.Shadowing name parentRegion region)



-- FIND TYPE


findType : A.Region -> Env -> Name.Name -> EResult i w Type
findType region { types, q_types } name =
    case Dict.get name types of
        Just (Specific _ tipe) ->
            R.ok tipe

        Just (Ambiguous h hs) ->
            R.throw (Error.AmbiguousType region Nothing name h hs)

        Nothing ->
            R.throw (Error.NotFoundType region Nothing name (toPossibleNames types q_types))


findTypeQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Type
findTypeQual region { types, q_types } prefix name =
    case Dict.get prefix q_types of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ tipe) ->
                    R.ok tipe

                Just (Ambiguous h hs) ->
                    R.throw (Error.AmbiguousType region (Just prefix) name h hs)

                Nothing ->
                    R.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))

        Nothing ->
            R.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames types q_types))



-- FIND CTOR


findCtor : A.Region -> Env -> Name.Name -> EResult i w Ctor
findCtor region { ctors, q_ctors } name =
    case Dict.get name ctors of
        Just (Specific _ ctor) ->
            R.ok ctor

        Just (Ambiguous h hs) ->
            R.throw (Error.AmbiguousVariant region Nothing name h hs)

        Nothing ->
            R.throw (Error.NotFoundVariant region Nothing name (toPossibleNames ctors q_ctors))


findCtorQual : A.Region -> Env -> Name.Name -> Name.Name -> EResult i w Ctor
findCtorQual region { ctors, q_ctors } prefix name =
    case Dict.get prefix q_ctors of
        Just qualified ->
            case Dict.get name qualified of
                Just (Specific _ pattern) ->
                    R.ok pattern

                Just (Ambiguous h hs) ->
                    R.throw (Error.AmbiguousVariant region (Just prefix) name h hs)

                Nothing ->
                    R.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))

        Nothing ->
            R.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames ctors q_ctors))



-- FIND BINOP


findBinop : A.Region -> Env -> Name.Name -> EResult i w Binop
findBinop region { binops } name =
    case Dict.get name binops of
        Just (Specific _ binop) ->
            R.ok binop

        Just (Ambiguous h hs) ->
            R.throw (Error.AmbiguousBinop region name h hs)

        Nothing ->
            R.throw (Error.NotFoundBinop region name (EverySet.fromList compare (Dict.keys binops)))



-- TO POSSIBLE NAMES


toPossibleNames : Exposed a -> Qualified a -> Error.PossibleNames
toPossibleNames exposed qualified =
    Error.PossibleNames (EverySet.fromList compare (Dict.keys exposed)) (Dict.map (\_ -> Dict.keys >> EverySet.fromList compare) qualified)
