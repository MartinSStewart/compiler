module AST.Utils.Type exposing
    ( dealias
    , deepDealias
    , delambda
    , iteratedDealias
    )

import AST.Canonical exposing (AliasType(..), FieldType(..), Type(..))
import Data.Map as Dict exposing (Dict)
import Data.Name exposing (Name)



-- DELAMBDA


delambda : Type -> List Type
delambda tipe =
    case tipe of
        TLambda arg result ->
            arg :: delambda result

        _ ->
            [ tipe ]



-- DEALIAS


dealias : List ( Name, Type ) -> AliasType -> Type
dealias args aliasType =
    case aliasType of
        Holey tipe ->
            dealiasHelp (Dict.fromList compare args) tipe

        Filled tipe ->
            tipe


dealiasHelp : Dict Name Type -> Type -> Type
dealiasHelp typeTable tipe =
    case tipe of
        TLambda a b ->
            TLambda
                (dealiasHelp typeTable a)
                (dealiasHelp typeTable b)

        TVar x ->
            Dict.get x typeTable
                |> Maybe.withDefault tipe

        TRecord fields ext ->
            TRecord (Dict.map (\_ -> dealiasField typeTable) fields) ext

        TAlias home name args t_ ->
            TAlias home name (List.map (Tuple.mapSecond (dealiasHelp typeTable)) args) t_

        TType home name args ->
            TType home name (List.map (dealiasHelp typeTable) args)

        TUnit ->
            TUnit

        TTuple a b maybeC ->
            TTuple
                (dealiasHelp typeTable a)
                (dealiasHelp typeTable b)
                (Maybe.map (dealiasHelp typeTable) maybeC)


dealiasField : Dict Name Type -> FieldType -> FieldType
dealiasField typeTable (FieldType index tipe) =
    FieldType index (dealiasHelp typeTable tipe)



-- DEEP DEALIAS


deepDealias : Type -> Type
deepDealias tipe =
    case tipe of
        TLambda a b ->
            TLambda (deepDealias a) (deepDealias b)

        TVar _ ->
            tipe

        TRecord fields ext ->
            TRecord (Dict.map (\_ -> deepDealiasField) fields) ext

        TAlias _ _ args tipe_ ->
            deepDealias (dealias args tipe_)

        TType home name args ->
            TType home name (List.map deepDealias args)

        TUnit ->
            TUnit

        TTuple a b c ->
            TTuple (deepDealias a) (deepDealias b) (Maybe.map deepDealias c)


deepDealiasField : FieldType -> FieldType
deepDealiasField (FieldType index tipe) =
    FieldType index (deepDealias tipe)



-- ITERATED DEALIAS


iteratedDealias : Type -> Type
iteratedDealias tipe =
    case tipe of
        TAlias _ _ args realType ->
            iteratedDealias (dealias args realType)

        _ ->
            tipe
