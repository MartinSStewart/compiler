module Type.Instantiate exposing
    ( FreeVars
    , fromSrcType
    )

import AST.Canonical as Can
import Data.IO as IO exposing (IO)
import Data.Map as Dict exposing (Dict)
import Data.Name exposing (Name)
import Type.Type exposing (Type(..))
import Utils.Main as Utils



-- FREE VARS


type alias FreeVars =
    Dict Name Type



-- FROM SOURCE TYPE


fromSrcType : Dict Name Type -> Can.Type -> IO Type
fromSrcType freeVars sourceType =
    case sourceType of
        Can.TLambda arg result ->
            IO.pure FunN
                |> IO.apply (fromSrcType freeVars arg)
                |> IO.apply (fromSrcType freeVars result)

        Can.TVar name ->
            IO.pure (Utils.find name freeVars)

        Can.TType home name args ->
            IO.fmap (AppN home name)
                (Utils.listTraverse (fromSrcType freeVars) args)

        Can.TAlias home name args aliasedType ->
            Utils.listTraverse (Utils.tupleTraverse (fromSrcType freeVars)) args
                |> IO.bind
                    (\targs ->
                        IO.fmap (AliasN home name targs)
                            (case aliasedType of
                                Can.Filled realType ->
                                    fromSrcType freeVars realType

                                Can.Holey realType ->
                                    fromSrcType (Dict.fromList compare targs) realType
                            )
                    )

        Can.TTuple a b maybeC ->
            IO.pure TupleN
                |> IO.apply (fromSrcType freeVars a)
                |> IO.apply (fromSrcType freeVars b)
                |> IO.apply (Utils.maybeTraverse (fromSrcType freeVars) maybeC)

        Can.TUnit ->
            IO.pure UnitN

        Can.TRecord fields maybeExt ->
            IO.pure RecordN
                |> IO.apply (Utils.mapTraverse compare (fromSrcFieldType freeVars) fields)
                |> IO.apply
                    (case maybeExt of
                        Nothing ->
                            IO.pure EmptyRecordN

                        Just ext ->
                            IO.pure (Utils.find ext freeVars)
                    )


fromSrcFieldType : Dict Name Type -> Can.FieldType -> IO Type
fromSrcFieldType freeVars (Can.FieldType _ tipe) =
    fromSrcType freeVars tipe
