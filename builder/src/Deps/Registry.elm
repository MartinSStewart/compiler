module Deps.Registry exposing
    ( KnownVersions(..)
    , Registry(..)
    , fetch
    , getVersions
    , getVersions_
    , knownVersionsDecoder
    , latest
    , read
    , registryDecoder
    , registryEncoder
    , update
    )

import Data.IO as IO exposing (IO(..))
import Data.Map as Dict exposing (Dict)
import Deps.Website as Website
import Elm.Package as Pkg
import Elm.Version as V
import File
import Http
import Json.Decode as Decode
import Json.DecodeX as D
import Json.Encode as Encode
import Json.EncodeX as E
import Parse.Primitives as P
import Reporting.Exit as Exit
import Stuff
import Utils.Main as Utils



-- REGISTRY


type Registry
    = Registry Int (Dict Pkg.Name KnownVersions)


type KnownVersions
    = KnownVersions V.Version (List V.Version)


knownVersionsDecoder : Decode.Decoder KnownVersions
knownVersionsDecoder =
    Decode.map2 KnownVersions
        (Decode.field "version" V.jsonDecoder)
        (Decode.field "versions" (Decode.list V.jsonDecoder))


knownVersionsEncoder : KnownVersions -> Encode.Value
knownVersionsEncoder (KnownVersions version versions) =
    Encode.object
        [ ( "version", V.jsonEncoder version )
        , ( "versions", Encode.list V.jsonEncoder versions )
        ]



-- READ


read : Stuff.PackageCache -> IO (Maybe Registry)
read cache =
    File.readBinary registryDecoder (Stuff.registry cache)



-- FETCH


fetch : Http.Manager -> Stuff.PackageCache -> IO (Result Exit.RegistryProblem Registry)
fetch manager cache =
    post manager "/all-packages" allPkgsDecoder <|
        \versions ->
            let
                size =
                    Dict.foldr (\_ -> addEntry) 0 versions

                registry =
                    Registry size versions

                path =
                    Stuff.registry cache
            in
            File.writeBinary registryEncoder path registry
                |> IO.fmap (\_ -> registry)


addEntry : KnownVersions -> Int -> Int
addEntry (KnownVersions _ vs) count =
    count + 1 + List.length vs


allPkgsDecoder : D.Decoder () (Dict Pkg.Name KnownVersions)
allPkgsDecoder =
    let
        keyDecoder : D.KeyDecoder () Pkg.Name
        keyDecoder =
            Pkg.keyDecoder bail

        versionsDecoder =
            D.list (D.mapError (\_ -> ()) V.decoder)

        toKnownVersions : List V.Version -> D.Decoder () KnownVersions
        toKnownVersions versions =
            case List.sortWith (Utils.flip V.compare) versions of
                v :: vs ->
                    D.pure (KnownVersions v vs)

                [] ->
                    D.failure ()
    in
    D.dict Pkg.compareName keyDecoder (D.bind toKnownVersions versionsDecoder)



-- UPDATE


update : Http.Manager -> Stuff.PackageCache -> Registry -> IO (Result Exit.RegistryProblem Registry)
update manager cache ((Registry size packages) as oldRegistry) =
    post manager ("/all-packages/since/" ++ String.fromInt size) (D.list newPkgDecoder) <|
        \news ->
            case news of
                [] ->
                    IO.pure oldRegistry

                _ :: _ ->
                    let
                        newSize =
                            size + List.length news

                        newPkgs =
                            List.foldr addNew packages news

                        newRegistry =
                            Registry newSize newPkgs
                    in
                    File.writeBinary registryEncoder (Stuff.registry cache) newRegistry
                        |> IO.fmap (\_ -> newRegistry)


addNew : ( Pkg.Name, V.Version ) -> Dict Pkg.Name KnownVersions -> Dict Pkg.Name KnownVersions
addNew ( name, version ) versions =
    let
        add maybeKnowns =
            case maybeKnowns of
                Just (KnownVersions v vs) ->
                    KnownVersions version (v :: vs)

                Nothing ->
                    KnownVersions version []
    in
    Dict.update Pkg.compareName name (Just << add) versions



-- NEW PACKAGE DECODER


newPkgDecoder : D.Decoder () ( Pkg.Name, V.Version )
newPkgDecoder =
    D.customString newPkgParser bail


newPkgParser : P.Parser () ( Pkg.Name, V.Version )
newPkgParser =
    P.specialize (\_ _ _ -> ()) Pkg.parser
        |> P.bind
            (\pkg ->
                P.word1 '@' bail
                    |> P.bind (\_ -> P.specialize (\_ _ _ -> ()) V.parser)
                    |> P.fmap (\vsn -> ( pkg, vsn ))
            )


bail : a -> b -> ()
bail _ _ =
    ()



-- LATEST


latest : Http.Manager -> Stuff.PackageCache -> IO (Result Exit.RegistryProblem Registry)
latest manager cache =
    read cache
        |> IO.bind
            (\maybeOldRegistry ->
                case maybeOldRegistry of
                    Just oldRegistry ->
                        update manager cache oldRegistry

                    Nothing ->
                        fetch manager cache
            )



-- GET VERSIONS


getVersions : Pkg.Name -> Registry -> Maybe KnownVersions
getVersions name (Registry _ versions) =
    Dict.get name versions


getVersions_ : Pkg.Name -> Registry -> Result (List Pkg.Name) KnownVersions
getVersions_ name (Registry _ versions) =
    case Dict.get name versions of
        Just kvs ->
            Ok kvs

        Nothing ->
            Err (Pkg.nearbyNames name (Dict.keys versions))



-- POST


post : Http.Manager -> String -> D.Decoder x a -> (a -> IO b) -> IO (Result Exit.RegistryProblem b)
post manager path decoder callback =
    let
        url =
            Website.route path []
    in
    Http.post manager url [] Exit.RP_Http <|
        \body ->
            case D.fromByteString decoder body of
                Ok a ->
                    IO.fmap Ok (callback a)

                Err _ ->
                    IO.pure <| Err <| Exit.RP_Data url body



-- ENCODERS and DECODERS


registryDecoder : Decode.Decoder Registry
registryDecoder =
    Decode.map2 Registry
        (Decode.field "size" Decode.int)
        (Decode.field "packages" (D.assocListDict Pkg.compareName Pkg.nameDecoder knownVersionsDecoder))


registryEncoder : Registry -> Encode.Value
registryEncoder (Registry size versions) =
    Encode.object
        [ ( "size", Encode.int size )
        , ( "packages", E.assocListDict Pkg.nameEncoder knownVersionsEncoder versions )
        ]
