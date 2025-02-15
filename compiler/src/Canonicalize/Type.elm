module Canonicalize.Type exposing
    ( canonicalize
    , toAnnotation
    )

import AST.Canonical as Can
import AST.Source as Src
import Canonicalize.Environment as Env
import Canonicalize.Environment.Dups as Dups
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Reporting.Annotation as A
import Reporting.Error.Canonicalize as Error
import Reporting.Result as R
import Utils.Main as Utils



-- RESULT


type alias CResult i w a =
    R.RResult i w Error.Error a



-- TO ANNOTATION


toAnnotation : Env.Env -> Src.Type -> CResult i w Can.Annotation
toAnnotation env srcType =
    canonicalize env srcType
        |> R.bind (\tipe -> R.ok (Can.Forall (addFreeVars Dict.empty tipe) tipe))



-- CANONICALIZE TYPES


canonicalize : Env.Env -> Src.Type -> CResult i w Can.Type
canonicalize env (A.At typeRegion tipe) =
    case tipe of
        Src.TVar x ->
            R.ok (Can.TVar x)

        Src.TType region name args ->
            Env.findType region env name
                |> R.bind (canonicalizeType env typeRegion name args)

        Src.TTypeQual region home name args ->
            Env.findTypeQual region env home name
                |> R.bind (canonicalizeType env typeRegion name args)

        Src.TLambda a b ->
            canonicalize env a
                |> R.fmap Can.TLambda
                |> R.bind
                    (\tLambda ->
                        R.fmap tLambda (canonicalize env b)
                    )

        Src.TRecord fields ext ->
            Dups.checkFields (canonicalizeFields env fields)
                |> R.bind (Utils.sequenceADict compare)
                |> R.fmap (\cfields -> Can.TRecord cfields (Maybe.map A.toValue ext))

        Src.TUnit ->
            R.ok Can.TUnit

        Src.TTuple a b cs ->
            canonicalize env a
                |> R.fmap Can.TTuple
                |> R.bind (\tTuple -> R.fmap tTuple (canonicalize env b))
                |> R.bind
                    (\tTuple ->
                        case cs of
                            [] ->
                                R.ok (tTuple Nothing)

                            [ c ] ->
                                canonicalize env c
                                    |> R.fmap (tTuple << Just)

                            _ ->
                                R.throw <| Error.TupleLargerThanThree typeRegion
                    )


canonicalizeFields : Env.Env -> List ( A.Located Name.Name, Src.Type ) -> List ( A.Located Name.Name, CResult i w Can.FieldType )
canonicalizeFields env fields =
    let
        canonicalizeField index ( name, srcType ) =
            ( name, R.fmap (Can.FieldType index) (canonicalize env srcType) )
    in
    List.indexedMap canonicalizeField fields



-- CANONICALIZE TYPE


canonicalizeType : Env.Env -> A.Region -> Name.Name -> List Src.Type -> Env.Type -> CResult i w Can.Type
canonicalizeType env region name args info =
    R.traverse (canonicalize env) args
        |> R.bind
            (\cargs ->
                case info of
                    Env.Alias arity home argNames aliasedType ->
                        checkArity arity region name args <|
                            Can.TAlias home name (List.map2 Tuple.pair argNames cargs) (Can.Holey aliasedType)

                    Env.Union arity home ->
                        checkArity arity region name args <|
                            Can.TType home name cargs
            )


checkArity : Int -> A.Region -> Name.Name -> List (A.Located arg) -> answer -> CResult i w answer
checkArity expected region name args answer =
    let
        actual =
            List.length args
    in
    if expected == actual then
        R.ok answer

    else
        R.throw (Error.BadArity region Error.TypeArity name expected actual)



-- ADD FREE VARS


addFreeVars : Dict Name.Name () -> Can.Type -> Dict Name.Name ()
addFreeVars freeVars tipe =
    case tipe of
        Can.TLambda arg result ->
            addFreeVars (addFreeVars freeVars result) arg

        Can.TVar var ->
            Dict.insert compare var () freeVars

        Can.TType _ _ args ->
            List.foldl (\b c -> addFreeVars c b) freeVars args

        Can.TRecord fields Nothing ->
            Dict.foldl (\_ b c -> addFieldFreeVars c b) freeVars fields

        Can.TRecord fields (Just ext) ->
            Dict.foldl (\_ b c -> addFieldFreeVars c b) (Dict.insert compare ext () freeVars) fields

        Can.TUnit ->
            freeVars

        Can.TTuple a b maybeC ->
            case maybeC of
                Nothing ->
                    addFreeVars (addFreeVars freeVars a) b

                Just c ->
                    addFreeVars (addFreeVars (addFreeVars freeVars a) b) c

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, arg ) fvs -> addFreeVars fvs arg) freeVars args


addFieldFreeVars : Dict Name.Name () -> Can.FieldType -> Dict Name.Name ()
addFieldFreeVars freeVars (Can.FieldType _ tipe) =
    addFreeVars freeVars tipe
