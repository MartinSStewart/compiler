module Elm.Compiler.Type.Extract exposing
    ( Types(..)
    , fromAnnotation
    , fromDependencyInterface
    , fromInterface
    , fromMsg
    , fromType
    , merge
    , mergeMany
    , typesDecoder
    , typesEncoder
    )

import AST.Canonical as Can
import AST.Optimized as Opt
import AST.Utils.Type as Type
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Data.Set as EverySet exposing (EverySet)
import Elm.Compiler.Type as T
import Elm.Interface as I
import Elm.ModuleName as ModuleName
import Json.Decode as Decode
import Json.DecodeX as D
import Json.Encode as Encode
import Json.EncodeX as E
import Maybe.Extra as Maybe
import Utils.Main as Utils



-- EXTRACTION


fromAnnotation : Can.Annotation -> T.Type
fromAnnotation (Can.Forall _ astType) =
    fromType astType


fromType : Can.Type -> T.Type
fromType astType =
    Tuple.second (run (extract astType))


extract : Can.Type -> Extractor T.Type
extract astType =
    case astType of
        Can.TLambda arg result ->
            pure T.Lambda
                |> apply (extract arg)
                |> apply (extract result)

        Can.TVar x ->
            pure (T.Var x)

        Can.TType home name args ->
            addUnion (Opt.Global home name) (T.Type (toPublicName home name))
                |> apply (traverse extract args)

        Can.TRecord fields ext ->
            traverse (tupleTraverse extract) (Can.fieldsToList fields)
                |> fmap (\efields -> T.Record efields ext)

        Can.TUnit ->
            pure T.Unit

        Can.TTuple a b maybeC ->
            pure T.Tuple
                |> apply (extract a)
                |> apply (extract b)
                |> apply (traverse extract (Maybe.toList maybeC))

        Can.TAlias home name args aliasType ->
            addAlias (Opt.Global home name) ()
                |> bind
                    (\_ ->
                        extract (Type.dealias args aliasType)
                            |> bind
                                (\_ ->
                                    fmap (T.Type (toPublicName home name))
                                        (traverse (extract << Tuple.second) args)
                                )
                    )


toPublicName : ModuleName.Canonical -> Name.Name -> Name.Name
toPublicName (ModuleName.Canonical _ home) name =
    Name.sepBy '.' home name



-- TRANSITIVELY AVAILABLE TYPES


type Types
    = -- PERF profile Opt.Global representation
      -- current representation needs less allocation
      -- but maybe the lookup is much worse
      Types (Dict ModuleName.Canonical Types_)


type Types_
    = Types_ (Dict Name.Name Can.Union) (Dict Name.Name Can.Alias)


mergeMany : List Types -> Types
mergeMany listOfTypes =
    case listOfTypes of
        [] ->
            Types Dict.empty

        t :: ts ->
            List.foldr merge t ts


merge : Types -> Types -> Types
merge (Types types1) (Types types2) =
    Types (Dict.union ModuleName.compareCanonical types1 types2)


fromInterface : ModuleName.Raw -> I.Interface -> Types
fromInterface name (I.Interface pkg _ unions aliases _) =
    Types <|
        Dict.singleton (ModuleName.Canonical pkg name) <|
            Types_ (Dict.map (\_ -> I.extractUnion) unions) (Dict.map (\_ -> I.extractAlias) aliases)


fromDependencyInterface : ModuleName.Canonical -> I.DependencyInterface -> Types
fromDependencyInterface home di =
    Types
        (Dict.singleton home <|
            case di of
                I.Public (I.Interface _ _ unions aliases _) ->
                    Types_ (Dict.map (\_ -> I.extractUnion) unions) (Dict.map (\_ -> I.extractAlias) aliases)

                I.Private _ unions aliases ->
                    Types_ unions aliases
        )



-- EXTRACT MODEL, MSG, AND ANY TRANSITIVE DEPENDENCIES


fromMsg : Types -> Can.Type -> T.DebugMetadata
fromMsg types message =
    let
        ( msgDeps, msgType ) =
            run (extract message)

        ( aliases, unions ) =
            extractTransitive types noDeps msgDeps
    in
    T.DebugMetadata msgType aliases unions


extractTransitive : Types -> Deps -> Deps -> ( List T.Alias, List T.Union )
extractTransitive types (Deps seenAliases seenUnions) (Deps nextAliases nextUnions) =
    let
        aliases =
            EverySet.diff nextAliases seenAliases

        unions =
            EverySet.diff nextUnions seenUnions
    in
    if EverySet.isEmpty aliases && EverySet.isEmpty unions then
        ( [], [] )

    else
        let
            ( newDeps, ( resultAlias, resultUnion ) ) =
                run
                    (pure Tuple.pair
                        |> apply (traverse (extractAlias types) (EverySet.toList aliases))
                        |> apply (traverse (extractUnion types) (EverySet.toList unions))
                    )

            oldDeps =
                Deps (EverySet.union Opt.compareGlobal seenAliases nextAliases) (EverySet.union Opt.compareGlobal seenUnions nextUnions)

            ( remainingResultAlias, remainingResultUnion ) =
                extractTransitive types oldDeps newDeps
        in
        ( resultAlias ++ remainingResultAlias, resultUnion ++ remainingResultUnion )


extractAlias : Types -> Opt.Global -> Extractor T.Alias
extractAlias (Types dict) (Opt.Global home name) =
    let
        (Can.Alias args aliasType) =
            Utils.find home dict
                |> (\(Types_ _ aliasInfo) -> aliasInfo)
                |> Utils.find name
    in
    fmap (T.Alias (toPublicName home name) args) (extract aliasType)


extractUnion : Types -> Opt.Global -> Extractor T.Union
extractUnion (Types dict) (Opt.Global home name) =
    if name == Name.list && home == ModuleName.list then
        pure <| T.Union (toPublicName home name) [ "a" ] []

    else
        let
            pname =
                toPublicName home name

            (Can.Union vars ctors _ _) =
                Utils.find home dict
                    |> (\(Types_ unionInfo _) -> unionInfo)
                    |> Utils.find name
        in
        fmap (T.Union pname vars) (traverse extractCtor ctors)


extractCtor : Can.Ctor -> Extractor ( Name.Name, List T.Type )
extractCtor (Can.Ctor ctor _ _ args) =
    fmap (Tuple.pair ctor) (traverse extract args)



-- DEPS


type Deps
    = Deps (EverySet Opt.Global) (EverySet Opt.Global)


noDeps : Deps
noDeps =
    Deps EverySet.empty EverySet.empty



-- EXTRACTOR


type Extractor a
    = Extractor (EverySet Opt.Global -> EverySet Opt.Global -> EResult a)


type EResult a
    = EResult (EverySet Opt.Global) (EverySet Opt.Global) a


run : Extractor a -> ( Deps, a )
run (Extractor k) =
    case k EverySet.empty EverySet.empty of
        EResult aliases unions value ->
            ( Deps aliases unions, value )


addAlias : Opt.Global -> a -> Extractor a
addAlias alias value =
    Extractor <|
        \aliases unions ->
            EResult (EverySet.insert Opt.compareGlobal alias aliases) unions value


addUnion : Opt.Global -> a -> Extractor a
addUnion union value =
    Extractor <|
        \aliases unions ->
            EResult aliases (EverySet.insert Opt.compareGlobal union unions) value


fmap : (a -> b) -> Extractor a -> Extractor b
fmap func (Extractor k) =
    Extractor <|
        \aliases unions ->
            case k aliases unions of
                EResult a1 u1 value ->
                    EResult a1 u1 (func value)


pure : a -> Extractor a
pure value =
    Extractor (\aliases unions -> EResult aliases unions value)


apply : Extractor a -> Extractor (a -> b) -> Extractor b
apply (Extractor kv) (Extractor kf) =
    Extractor <|
        \aliases unions ->
            case kf aliases unions of
                EResult a1 u1 func ->
                    case kv a1 u1 of
                        EResult a2 u2 value ->
                            EResult a2 u2 (func value)


bind : (a -> Extractor b) -> Extractor a -> Extractor b
bind callback (Extractor ka) =
    Extractor <|
        \aliases unions ->
            case ka aliases unions of
                EResult a1 u1 value ->
                    case callback value of
                        Extractor kb ->
                            kb a1 u1


traverse : (a -> Extractor b) -> List a -> Extractor (List b)
traverse f =
    List.foldr (\a -> bind (\c -> fmap (\va -> va :: c) (f a)))
        (pure [])


tupleTraverse : (b -> Extractor c) -> ( a, b ) -> Extractor ( a, c )
tupleTraverse f ( a, b ) =
    fmap (Tuple.pair a) (f b)



-- ENCODERS and DECODERS


typesEncoder : Types -> Encode.Value
typesEncoder (Types types) =
    E.assocListDict ModuleName.canonicalEncoder types_Encoder types


typesDecoder : Decode.Decoder Types
typesDecoder =
    Decode.map Types (D.assocListDict ModuleName.compareCanonical ModuleName.canonicalDecoder types_Decoder)


types_Encoder : Types_ -> Encode.Value
types_Encoder (Types_ unionInfo aliasInfo) =
    Encode.object
        [ ( "type", Encode.string "Types_" )
        , ( "unionInfo", E.assocListDict Encode.string Can.unionEncoder unionInfo )
        , ( "aliasInfo", E.assocListDict Encode.string Can.aliasEncoder aliasInfo )
        ]


types_Decoder : Decode.Decoder Types_
types_Decoder =
    Decode.map2 Types_
        (Decode.field "unionInfo" (D.assocListDict compare Decode.string Can.unionDecoder))
        (Decode.field "aliasInfo" (D.assocListDict compare Decode.string Can.aliasDecoder))
