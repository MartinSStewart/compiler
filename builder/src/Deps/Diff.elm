module Deps.Diff exposing
    ( Changes
    , ModuleChanges(..)
    , PackageChanges(..)
    , bump
    , diff
    , getDocs
    , moduleChangeMagnitude
    , toMagnitude
    )

import Basics.Extra exposing (uncurry)
import Data.IO as IO exposing (IO)
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Data.Set as EverySet
import Deps.Website as Website
import Elm.Compiler.Type as Type
import Elm.Docs as Docs
import Elm.Magnitude as M
import Elm.ModuleName as ModuleName
import Elm.Package as Pkg
import Elm.Version as V exposing (Version)
import File
import Http
import Json.DecodeX as D
import List
import Maybe.Extra
import Reporting.Exit as Exit exposing (DocsProblem(..))
import Stuff
import Task
import Utils.Main as Utils


type PackageChanges
    = PackageChanges (List ModuleName.Raw) (Dict ModuleName.Raw ModuleChanges) (List ModuleName.Raw)


type ModuleChanges
    = ModuleChanges (Changes Name.Name Docs.Union) (Changes Name.Name Docs.Alias) (Changes Name.Name Docs.Value) (Changes Name.Name Docs.Binop)


type Changes k v
    = Changes (Dict k v) (Dict k ( v, v )) (Dict k v)


getChanges : (k -> k -> Order) -> (v -> v -> Bool) -> Dict k v -> Dict k v -> Changes k v
getChanges keyComparison isEquivalent old new =
    let
        overlap =
            Utils.mapIntersectionWith keyComparison Tuple.pair old new

        changed =
            Dict.filter (\_ ( v1, v2 ) -> not (isEquivalent v1 v2)) overlap
    in
    Changes
        (Dict.diff new old)
        changed
        (Dict.diff old new)



-- DIFF


diff : Docs.Documentation -> Docs.Documentation -> PackageChanges
diff oldDocs newDocs =
    let
        filterOutPatches chngs =
            Dict.filter (\_ chng -> moduleChangeMagnitude chng /= M.PATCH) chngs

        (Changes added changed removed) =
            getChanges compare (\_ _ -> False) oldDocs newDocs
    in
    PackageChanges
        (Dict.keys added)
        (filterOutPatches (Dict.map (\_ -> diffModule) changed))
        (Dict.keys removed)


diffModule : ( Docs.Module, Docs.Module ) -> ModuleChanges
diffModule ( Docs.Module _ _ u1 a1 v1 b1, Docs.Module _ _ u2 a2 v2 b2 ) =
    ModuleChanges
        (getChanges compare isEquivalentUnion u1 u2)
        (getChanges compare isEquivalentAlias a1 a2)
        (getChanges compare isEquivalentValue v1 v2)
        (getChanges compare isEquivalentBinop b1 b2)



-- EQUIVALENCE


isEquivalentUnion : Docs.Union -> Docs.Union -> Bool
isEquivalentUnion (Docs.Union oldComment oldVars oldCtors) (Docs.Union newComment newVars newCtors) =
    (List.length oldCtors == List.length newCtors)
        && (List.map Tuple.first oldCtors == List.map Tuple.first newCtors)
        && List.all
            (\( oldCtors_, newCtors_ ) ->
                List.map2
                    isEquivalentAlias
                    (List.map (\oldTypes -> Docs.Alias oldComment oldVars oldTypes) oldCtors_)
                    (List.map (\newTypes -> Docs.Alias newComment newVars newTypes) newCtors_)
                    |> List.all identity
            )
            (List.map2 Tuple.pair oldCtors newCtors)


isEquivalentAlias : Docs.Alias -> Docs.Alias -> Bool
isEquivalentAlias (Docs.Alias _ oldVars oldType) (Docs.Alias _ newVars newType) =
    case diffType oldType newType of
        Nothing ->
            False

        Just renamings ->
            (List.length oldVars == List.length newVars)
                && isEquivalentRenaming (List.map2 Tuple.pair oldVars newVars ++ renamings)


isEquivalentValue : Docs.Value -> Docs.Value -> Bool
isEquivalentValue (Docs.Value c1 t1) (Docs.Value c2 t2) =
    isEquivalentAlias (Docs.Alias c1 [] t1) (Docs.Alias c2 [] t2)


isEquivalentBinop : Docs.Binop -> Docs.Binop -> Bool
isEquivalentBinop (Docs.Binop c1 t1 a1 p1) (Docs.Binop c2 t2 a2 p2) =
    isEquivalentAlias (Docs.Alias c1 [] t1) (Docs.Alias c2 [] t2)
        && a1
        == a2
        && p1
        == p2



-- DIFF TYPES


diffType : Type.Type -> Type.Type -> Maybe (List ( Name.Name, Name.Name ))
diffType oldType newType =
    case ( oldType, newType ) of
        ( Type.Var oldName, Type.Var newName ) ->
            Just [ ( oldName, newName ) ]

        ( Type.Lambda a b, Type.Lambda a_ b_ ) ->
            Maybe.map2 (++) (diffType a a_) (diffType b b_)

        ( Type.Type oldName oldArgs, Type.Type newName newArgs ) ->
            if not (isSameName oldName newName) || List.length oldArgs /= List.length newArgs then
                Nothing

            else
                List.concatMap (uncurry diffType) (List.map2 Tuple.pair oldArgs newArgs)
                    |> Maybe.Extra.join

        ( Type.Record fields maybeExt, Type.Record fields_ maybeExt_ ) ->
            case ( maybeExt, maybeExt_ ) of
                ( Nothing, Just _ ) ->
                    Nothing

                ( Just _, Nothing ) ->
                    Nothing

                ( Nothing, Nothing ) ->
                    diffFields fields fields_

                ( Just oldExt, Just newExt ) ->
                    Maybe.map ((::) ( oldExt, newExt )) (diffFields fields fields_)

        ( Type.Unit, Type.Unit ) ->
            Just []

        ( Type.Tuple a b cs, Type.Tuple x y zs ) ->
            if List.length cs /= List.length zs then
                Nothing

            else
                Maybe.map3 (++)
                    (diffType a x)
                    (diffType b y)
                    (List.concatMap (uncurry diffType) (List.map2 Tuple.pair cs zs)
                        |> Maybe.Extra.join
                    )

        ( _, _ ) ->
            Nothing



-- handle very old docs that do not use qualified names


isSameName : Name.Name -> Name.Name -> Bool
isSameName oldFullName newFullName =
    let
        dedot name =
            List.reverse (String.split "." name)
    in
    case ( dedot oldFullName, dedot newFullName ) of
        ( oldName :: [], newName :: _ ) ->
            oldName == newName

        ( oldName :: _, newName :: [] ) ->
            oldName == newName

        _ ->
            oldFullName == newFullName


diffFields : List ( Name.Name, Type.Type ) -> List ( Name.Name, Type.Type ) -> Maybe (List ( Name.Name, Name.Name ))
diffFields oldRawFields newRawFields =
    let
        sort fields =
            List.sortBy Tuple.first fields

        oldFields =
            sort oldRawFields

        newFields =
            sort newRawFields
    in
    -- if List.length oldRawFields /= List.length newRawFields then
    --     Nothing
    -- else if List.any2 (/=) (List.map Tuple.first oldFields) (List.map Tuple.first newFields) then
    --     Nothing
    -- else
    --     List.concatMap (uncurry diffType) (List.map2 Tuple.pair (List.map Tuple.second oldFields) (List.map Tuple.second newFields))
    --         |> Maybe.Extra.join
    Debug.todo "diffFields"



-- TYPE VARIABLES


isEquivalentRenaming : List ( Name.Name, Name.Name ) -> Bool
isEquivalentRenaming varPairs =
    let
        renamings =
            List.foldr
                (\( old, new ) dict ->
                    Dict.update
                        old
                        (Maybe.map ((::) new) >> Maybe.withDefault [ new ] >> Just)
                        dict
                )
                Dict.empty
                varPairs

        verify ( old, news ) =
            case news of
                [] ->
                    Nothing

                new :: rest ->
                    if List.all ((==) new) rest then
                        Just ( old, new )

                    else
                        Nothing

        allUnique list =
            List.length list == EverySet.size (EverySet.fromList list)
    in
    case List.filterMap verify (Dict.toList renamings) of
        [] ->
            False

        verifiedRenamings ->
            List.all compatibleVars verifiedRenamings
                && allUnique (List.map Tuple.second verifiedRenamings)


compatibleVars : ( Name.Name, Name.Name ) -> Bool
compatibleVars ( old, new ) =
    case ( categorizeVar old, categorizeVar new ) of
        ( CompAppend, CompAppend ) ->
            True

        ( Comparable, Comparable ) ->
            True

        ( Appendable, Appendable ) ->
            True

        ( Number, Number ) ->
            True

        ( Number, Comparable ) ->
            True

        ( _, Var ) ->
            True

        ( _, _ ) ->
            False


type TypeVarCategory
    = CompAppend
    | Comparable
    | Appendable
    | Number
    | Var


categorizeVar : Name.Name -> TypeVarCategory
categorizeVar name =
    if Name.isCompappendType name then
        CompAppend

    else if Name.isComparableType name then
        Comparable

    else if Name.isAppendableType name then
        Appendable

    else if Name.isNumberType name then
        Number

    else
        Var



-- MAGNITUDE


bump : PackageChanges -> Version -> Version
bump changes version =
    case toMagnitude changes of
        M.PATCH ->
            V.bumpPatch version

        M.MINOR ->
            V.bumpMinor version

        M.MAJOR ->
            V.bumpMajor version


toMagnitude : PackageChanges -> M.Magnitude
toMagnitude (PackageChanges added changed removed) =
    let
        addMag =
            if List.isEmpty added then
                M.PATCH

            else
                M.MINOR

        removeMag =
            if List.isEmpty removed then
                M.PATCH

            else
                M.MAJOR

        changeMags =
            List.map moduleChangeMagnitude (Dict.values changed)
    in
    Utils.listMaximum (addMag :: removeMag :: changeMags)


moduleChangeMagnitude : ModuleChanges -> M.Magnitude
moduleChangeMagnitude (ModuleChanges unions aliases values binops) =
    Utils.listMaximum
        [ changeMagnitude unions
        , changeMagnitude aliases
        , changeMagnitude values
        , changeMagnitude binops
        ]


changeMagnitude : Changes k v -> M.Magnitude
changeMagnitude (Changes added changed removed) =
    if not (Dict.isEmpty removed || Dict.isEmpty changed) then
        M.MAJOR

    else if not (Dict.isEmpty added) then
        M.MINOR

    else
        M.PATCH



-- GET DOCS


getDocs : Stuff.PackageCache -> Http.Manager -> Pkg.Name -> V.Version -> IO (Result Exit.DocsProblem Docs.Documentation)
getDocs cache manager name version =
    let
        home =
            Stuff.package cache name version

        path =
            home ++ "/docs.json"
    in
    File.exists path
        |> IO.bind
            (\exists ->
                if exists then
                    File.readUtf8 path
                        |> IO.bind
                            (\bytes ->
                                case D.fromByteString Docs.decoder bytes of
                                    Ok docs ->
                                        IO.pure (Ok docs)

                                    Err _ ->
                                        File.remove path
                                            |> IO.fmap (\_ -> Err DP_Cache)
                            )

                else
                    let
                        url =
                            Website.metadata name version "docs.json"
                    in
                    Http.get manager url [] Exit.DP_Http <|
                        \body ->
                            case D.fromByteString Docs.decoder body of
                                Ok docs ->
                                    Utils.dirCreateDirectoryIfMissing True home
                                        |> IO.bind (\_ -> File.writeUtf8 path body)
                                        |> IO.fmap (\_ -> Ok docs)

                                Err _ ->
                                    IO.pure (Err (DP_Data url body))
            )
