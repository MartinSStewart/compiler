module Canonicalize.Environment.Foreign exposing (createInitialEnv)

import AST.Canonical as Can
import AST.Source as Src
import Canonicalize.Environment as Env
import Data.Map as Dict exposing (Dict)
import Data.Name as Name exposing (Name)
import Elm.Interface as I
import Elm.Kernel exposing (Chunk(..))
import Elm.ModuleName as ModuleName
import Elm.Package as Pkg
import Reporting.Annotation as A
import Reporting.Error.Canonicalize as Error
import Reporting.Result as R
import Utils.Crash exposing (crash)
import Utils.Main as Utils


type alias FResult i w a =
    R.RResult i w Error.Error a


createInitialEnv : ModuleName.Canonical -> Dict ModuleName.Raw I.Interface -> List Src.Import -> FResult i w Env.Env
createInitialEnv home ifaces imports =
    Utils.foldM (addImport ifaces) emptyState (toSafeImports home imports)
        |> R.fmap
            (\{ vars, types, ctors, binops, q_vars, q_types, q_ctors } ->
                Env.Env home
                    (Dict.map (\_ -> infoToVar) vars)
                    types
                    ctors
                    binops
                    q_vars
                    q_types
                    q_ctors
            )


infoToVar : Env.Info Can.Annotation -> Env.Var
infoToVar info =
    case info of
        Env.Specific home tipe ->
            Env.Foreign home tipe

        Env.Ambiguous h hs ->
            Env.Foreigns h hs



-- STATE


type alias State =
    { vars : Env.Exposed Can.Annotation
    , types : Env.Exposed Env.Type
    , ctors : Env.Exposed Env.Ctor
    , binops : Env.Exposed Env.Binop
    , q_vars : Env.Qualified Can.Annotation
    , q_types : Env.Qualified Env.Type
    , q_ctors : Env.Qualified Env.Ctor
    }


emptyState : State
emptyState =
    State Dict.empty emptyTypes Dict.empty Dict.empty Dict.empty Dict.empty Dict.empty


emptyTypes : Env.Exposed Env.Type
emptyTypes =
    Dict.fromList compare [ ( "List", Env.Specific ModuleName.list (Env.Union 1 ModuleName.list) ) ]



-- TO SAFE IMPORTS


toSafeImports : ModuleName.Canonical -> List Src.Import -> List Src.Import
toSafeImports (ModuleName.Canonical package _) imports =
    if Pkg.isKernel package then
        List.filter isNormal imports

    else
        imports


isNormal : Src.Import -> Bool
isNormal (Src.Import (A.At _ name) maybeAlias _) =
    if Name.isKernel name then
        case maybeAlias of
            Nothing ->
                False

            Just _ ->
                crash "kernel imports cannot use `as`"

    else
        True



-- ADD IMPORTS


addImport : Dict ModuleName.Raw I.Interface -> State -> Src.Import -> FResult i w State
addImport ifaces state (Src.Import (A.At _ name) maybeAlias exposing_) =
    let
        (I.Interface pkg defs unions aliases binops) =
            Utils.find name ifaces

        prefix =
            Maybe.withDefault name maybeAlias

        home =
            ModuleName.Canonical pkg name

        rawTypeInfo =
            Dict.union compare
                (Dict.toList unions
                    |> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (unionToType home k a))
                    |> Dict.fromList compare
                )
                (Dict.toList aliases
                    |> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (aliasToType home k a))
                    |> Dict.fromList compare
                )

        vars =
            Dict.map (\_ -> Env.Specific home) defs

        types =
            Dict.map (\_ -> Env.Specific home << Tuple.first) rawTypeInfo

        ctors =
            Dict.foldr (\_ -> addExposed << Tuple.second) Dict.empty rawTypeInfo

        qvs2 =
            addQualified prefix vars state.q_vars

        qts2 =
            addQualified prefix types state.q_types

        qcs2 =
            addQualified prefix ctors state.q_ctors
    in
    case exposing_ of
        Src.Open ->
            let
                vs2 =
                    addExposed state.vars vars

                ts2 =
                    addExposed state.types types

                cs2 =
                    addExposed state.ctors ctors

                bs2 =
                    addExposed state.binops (Dict.map (binopToBinop home) binops)
            in
            R.ok (State vs2 ts2 cs2 bs2 qvs2 qts2 qcs2)

        Src.Explicit exposedList ->
            Utils.foldM
                (addExposedValue home vars rawTypeInfo binops)
                (State state.vars state.types state.ctors state.binops qvs2 qts2 qcs2)
                exposedList


addExposed : Env.Exposed a -> Env.Exposed a -> Env.Exposed a
addExposed =
    Utils.mapUnionWith compare Env.mergeInfo


addQualified : Name -> Env.Exposed a -> Env.Qualified a -> Env.Qualified a
addQualified prefix exposed qualified =
    Utils.mapInsertWith compare addExposed prefix exposed qualified



-- UNION


unionToType : ModuleName.Canonical -> Name -> I.Union -> Maybe ( Env.Type, Env.Exposed Env.Ctor )
unionToType home name union =
    Maybe.map (unionToTypeHelp home name) (I.toPublicUnion union)


unionToTypeHelp : ModuleName.Canonical -> Name -> Can.Union -> ( Env.Type, Env.Exposed Env.Ctor )
unionToTypeHelp home name ((Can.Union vars ctors _ _) as union) =
    let
        addCtor (Can.Ctor ctor index _ args) dict =
            Dict.insert compare ctor (Env.Specific home (Env.Ctor home name union index args)) dict
    in
    ( Env.Union (List.length vars) home
    , List.foldl addCtor Dict.empty ctors
    )



-- ALIAS


aliasToType : ModuleName.Canonical -> Name -> I.Alias -> Maybe ( Env.Type, Env.Exposed Env.Ctor )
aliasToType home name alias =
    Maybe.map (aliasToTypeHelp home name) (I.toPublicAlias alias)


aliasToTypeHelp : ModuleName.Canonical -> Name -> Can.Alias -> ( Env.Type, Env.Exposed Env.Ctor )
aliasToTypeHelp home name (Can.Alias vars tipe) =
    ( Env.Alias (List.length vars) home vars tipe
    , case tipe of
        Can.TRecord fields Nothing ->
            let
                avars =
                    List.map (\var -> ( var, Can.TVar var )) vars

                alias_ =
                    List.foldr
                        (\( _, t1 ) t2 -> Can.TLambda t1 t2)
                        (Can.TAlias home name avars (Can.Filled tipe))
                        (Can.fieldsToList fields)
            in
            Dict.singleton name (Env.Specific home (Env.RecordCtor home vars alias_))

        _ ->
            Dict.empty
    )



-- BINOP


binopToBinop : ModuleName.Canonical -> Name -> I.Binop -> Env.Info Env.Binop
binopToBinop home op (I.Binop name annotation associativity precedence) =
    Env.Specific home (Env.Binop op home name annotation associativity precedence)



-- ADD EXPOSED VALUE


addExposedValue :
    ModuleName.Canonical
    -> Env.Exposed Can.Annotation
    -> Dict Name ( Env.Type, Env.Exposed Env.Ctor )
    -> Dict Name I.Binop
    -> State
    -> Src.Exposed
    -> FResult i w State
addExposedValue home vars types binops state exposed =
    case exposed of
        Src.Lower (A.At region name) ->
            case Dict.get name vars of
                Just info ->
                    R.ok { state | vars = Utils.mapInsertWith compare Env.mergeInfo name info state.vars }

                Nothing ->
                    R.throw (Error.ImportExposingNotFound region home name (Dict.keys vars))

        Src.Upper (A.At region name) privacy ->
            case privacy of
                Src.Private ->
                    case Dict.get name types of
                        Just ( tipe, ctors ) ->
                            case tipe of
                                Env.Union _ _ ->
                                    let
                                        ts2 =
                                            Dict.insert compare name (Env.Specific home tipe) state.types
                                    in
                                    R.ok { state | types = ts2 }

                                Env.Alias _ _ _ _ ->
                                    let
                                        ts2 =
                                            Dict.insert compare name (Env.Specific home tipe) state.types

                                        cs2 =
                                            addExposed state.ctors ctors
                                    in
                                    R.ok { state | types = ts2, ctors = cs2 }

                        Nothing ->
                            case checkForCtorMistake name types of
                                tipe :: _ ->
                                    R.throw <| Error.ImportCtorByName region name tipe

                                [] ->
                                    R.throw <| Error.ImportExposingNotFound region home name (Dict.keys types)

                Src.Public dotDotRegion ->
                    case Dict.get name types of
                        Just ( tipe, ctors ) ->
                            case tipe of
                                Env.Union _ _ ->
                                    let
                                        ts2 =
                                            Dict.insert compare name (Env.Specific home tipe) state.types

                                        cs2 =
                                            addExposed state.ctors ctors
                                    in
                                    R.ok { state | types = ts2, ctors = cs2 }

                                Env.Alias _ _ _ _ ->
                                    R.throw (Error.ImportOpenAlias dotDotRegion name)

                        Nothing ->
                            R.throw (Error.ImportExposingNotFound region home name (Dict.keys types))

        Src.Operator region op ->
            case Dict.get op binops of
                Just binop ->
                    let
                        bs2 =
                            Dict.insert compare op (binopToBinop home op binop) state.binops
                    in
                    R.ok { state | binops = bs2 }

                Nothing ->
                    R.throw (Error.ImportExposingNotFound region home op (Dict.keys binops))


checkForCtorMistake : Name -> Dict Name ( Env.Type, Env.Exposed Env.Ctor ) -> List Name
checkForCtorMistake givenName types =
    let
        addMatches _ ( _, exposedCtors ) matches =
            Dict.foldr addMatch matches exposedCtors

        addMatch ctorName info matches =
            if ctorName /= givenName then
                matches

            else
                case info of
                    Env.Specific _ (Env.Ctor _ tipeName _ _ _) ->
                        tipeName :: matches

                    Env.Specific _ (Env.RecordCtor _ _ _) ->
                        matches

                    Env.Ambiguous _ _ ->
                        matches
    in
    Dict.foldr addMatches [] types
