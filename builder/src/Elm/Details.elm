module Elm.Details exposing
    ( BuildID
    , Details(..)
    , Foreign(..)
    , Local(..)
    , ValidOutline(..)
    , detailsEncoder
    , load
    , loadInterfaces
    , loadObjects
    , localDecoder
    , localEncoder
    , statusDecoder
    , verifyInstall
    )

import AST.Canonical as Can
import AST.Optimized as Opt
import AST.Source as Src
import BackgroundWriter as BW
import Compile
import Data.IO as IO exposing (IO)
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Data.NonEmptyList as NE
import Data.OneOrMore as OneOrMore
import Data.Set as EverySet exposing (EverySet)
import Deps.Registry as Registry
import Deps.Solver as Solver
import Deps.Website as Website
import Elm.Constraint as Con
import Elm.Docs as Docs
import Elm.Interface as I
import Elm.Kernel as Kernel
import Elm.ModuleName as ModuleName
import Elm.Outline as Outline
import Elm.Package as Pkg
import Elm.Version as V
import File
import Http
import Json.Decode as Decode
import Json.DecodeX as D
import Json.Encode as Encode
import Json.EncodeX as E
import Parse.Module as Parse
import Reporting
import Reporting.Annotation as A
import Reporting.Exit as Exit
import Reporting.Task as Task
import Stuff
import Utils.Crash exposing (crash)
import Utils.Main as Utils exposing (FilePath, MVar)



-- DETAILS


type Details
    = Details File.Time ValidOutline BuildID (Dict ModuleName.Raw Local) (Dict ModuleName.Raw Foreign) Extras


type alias BuildID =
    Int


type ValidOutline
    = ValidApp (NE.Nonempty Outline.SrcDir)
    | ValidPkg Pkg.Name (List ModuleName.Raw) (Dict Pkg.Name V.Version {- for docs in reactor -})



-- NOTE: we need two ways to detect if a file must be recompiled:
--
-- (1) _time is the modification time from the last time we compiled the file.
-- By checking EQUALITY with the current modification time, we can detect file
-- saves and `git checkout` of previous versions. Both need a recompile.
--
-- (2) _lastChange is the BuildID from the last time a new interface file was
-- generated, and _lastCompile is the BuildID from the last time the file was
-- compiled. These may be different if a file is recompiled but the interface
-- stayed the same. When the _lastCompile is LESS THAN the _lastChange of any
-- imports, we need to recompile. This can happen when a project has multiple
-- entrypoints and some modules are compiled less often than their imports.
--


type Local
    = Local FilePath File.Time (List ModuleName.Raw) Bool BuildID BuildID


type Foreign
    = Foreign Pkg.Name (List Pkg.Name)


type Extras
    = ArtifactsCached
    | ArtifactsFresh Interfaces Opt.GlobalGraph


type alias Interfaces =
    Dict ModuleName.Canonical I.DependencyInterface



-- LOAD ARTIFACTS


loadObjects : FilePath -> Details -> IO (MVar (Maybe Opt.GlobalGraph))
loadObjects root (Details _ _ _ _ _ extras) =
    case extras of
        ArtifactsFresh _ o ->
            Utils.newMVar (Utils.maybeEncoder Opt.globalGraphEncoder) (Just o)

        ArtifactsCached ->
            fork (Utils.maybeEncoder Opt.globalGraphEncoder) (File.readBinary Opt.globalGraphDecoder (Stuff.objects root))


loadInterfaces : FilePath -> Details -> IO (MVar (Maybe Interfaces))
loadInterfaces root (Details _ _ _ _ _ extras) =
    case extras of
        ArtifactsFresh i _ ->
            Utils.newMVar (Utils.maybeEncoder interfacesEncoder) (Just i)

        ArtifactsCached ->
            fork (Utils.maybeEncoder interfacesEncoder) (File.readBinary interfacesDecoder (Stuff.interfaces root))



-- VERIFY INSTALL -- used by Install


verifyInstall : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> IO (Result Exit.Details ())
verifyInstall scope root (Solver.Env cache manager connection registry) outline =
    File.getTime (root ++ "/elm.json")
        |> IO.bind
            (\time ->
                let
                    key =
                        Reporting.ignorer

                    env =
                        Env key scope root cache manager connection registry
                in
                case outline of
                    Outline.Pkg pkg ->
                        Task.run (Task.fmap (\_ -> ()) (verifyPkg env time pkg))

                    Outline.App app ->
                        Task.run (Task.fmap (\_ -> ()) (verifyApp env time app))
            )



-- LOAD -- used by Make, Repl, Reactor


load : Reporting.Style -> BW.Scope -> FilePath -> IO (Result Exit.Details Details)
load style scope root =
    File.getTime (root ++ "/elm.json")
        |> IO.bind
            (\newTime ->
                File.readBinary detailsDecoder (Stuff.details root)
                    |> IO.bind
                        (\maybeDetails ->
                            case maybeDetails of
                                Nothing ->
                                    generate style scope root newTime

                                Just (Details oldTime outline buildID locals foreigns extras) ->
                                    if oldTime == newTime then
                                        IO.pure (Ok (Details oldTime outline (buildID + 1) locals foreigns extras))

                                    else
                                        generate style scope root newTime
                        )
            )



-- GENERATE


generate : Reporting.Style -> BW.Scope -> FilePath -> File.Time -> IO (Result Exit.Details Details)
generate style scope root time =
    Reporting.trackDetails style
        (\key ->
            initEnv key scope root
                |> IO.bind
                    (\result ->
                        case result of
                            Err exit ->
                                IO.pure (Err exit)

                            Ok ( env, outline ) ->
                                case outline of
                                    Outline.Pkg pkg ->
                                        Task.run (verifyPkg env time pkg)

                                    Outline.App app ->
                                        Task.run (verifyApp env time app)
                    )
        )



-- ENV


type Env
    = Env Reporting.DKey BW.Scope FilePath Stuff.PackageCache Http.Manager Solver.Connection Registry.Registry


initEnv : Reporting.DKey -> BW.Scope -> FilePath -> IO (Result Exit.Details ( Env, Outline.Outline ))
initEnv key scope root =
    fork resultRegistryProblemEnvEncoder Solver.initEnv
        |> IO.bind
            (\mvar ->
                Outline.read root
                    |> IO.bind
                        (\eitherOutline ->
                            case eitherOutline of
                                Err problem ->
                                    IO.pure (Err (Exit.DetailsBadOutline problem))

                                Ok outline ->
                                    Utils.readMVar resultRegistryProblemEnvDecoder mvar
                                        |> IO.fmap
                                            (\maybeEnv ->
                                                case maybeEnv of
                                                    Err problem ->
                                                        Err (Exit.DetailsCannotGetRegistry problem)

                                                    Ok (Solver.Env cache manager connection registry) ->
                                                        Ok ( Env key scope root cache manager connection registry, outline )
                                            )
                        )
            )



-- VERIFY PROJECT


type alias Task a =
    Task.Task Exit.Details a


verifyPkg : Env -> File.Time -> Outline.PkgOutline -> Task Details
verifyPkg env time (Outline.PkgOutline pkg _ _ _ exposed direct testDirect elm) =
    if Con.goodElm elm then
        union Pkg.compareName noDups direct testDirect
            |> Task.bind (verifyConstraints env)
            |> Task.bind
                (\solution ->
                    let
                        exposedList =
                            Outline.flattenExposed exposed

                        exactDeps =
                            Dict.map (\_ (Solver.Details v _) -> v) solution

                        -- for pkg docs in reactor
                    in
                    verifyDependencies env time (ValidPkg pkg exposedList exactDeps) solution direct
                )

    else
        Task.throw (Exit.DetailsBadElmInPkg elm)


verifyApp : Env -> File.Time -> Outline.AppOutline -> Task Details
verifyApp env time ((Outline.AppOutline elmVersion srcDirs direct _ _ _) as outline) =
    if elmVersion == V.compiler then
        checkAppDeps outline
            |> Task.bind
                (\stated ->
                    verifyConstraints env (Dict.map (\_ -> Con.exactly) stated)
                        |> Task.bind
                            (\actual ->
                                if Dict.size stated == Dict.size actual then
                                    verifyDependencies env time (ValidApp srcDirs) actual direct

                                else
                                    Task.throw Exit.DetailsHandEditedDependencies
                            )
                )

    else
        Task.throw (Exit.DetailsBadElmInAppOutline elmVersion)


checkAppDeps : Outline.AppOutline -> Task (Dict Pkg.Name V.Version)
checkAppDeps (Outline.AppOutline _ _ direct indirect testDirect testIndirect) =
    union Pkg.compareName allowEqualDups indirect testDirect
        |> Task.bind
            (\x ->
                union Pkg.compareName noDups direct testIndirect
                    |> Task.bind (\y -> union Pkg.compareName noDups x y)
            )



-- VERIFY CONSTRAINTS


verifyConstraints : Env -> Dict Pkg.Name Con.Constraint -> Task (Dict Pkg.Name Solver.Details)
verifyConstraints (Env _ _ _ cache _ connection registry) constraints =
    Task.io (Solver.verify cache connection registry constraints)
        |> Task.bind
            (\result ->
                case result of
                    Solver.SolverOk details ->
                        Task.pure details

                    Solver.NoSolution ->
                        Task.throw Exit.DetailsNoSolution

                    Solver.NoOfflineSolution ->
                        Task.throw Exit.DetailsNoOfflineSolution

                    Solver.SolverErr exit ->
                        Task.throw (Exit.DetailsSolverProblem exit)
            )



-- UNION


union : (k -> k -> Order) -> (k -> v -> v -> Task v) -> Dict k v -> Dict k v -> Task (Dict k v)
union keyComparison tieBreaker deps1 deps2 =
    Dict.merge
        (\k dep -> Task.fmap (Dict.insert keyComparison k dep))
        (\k dep1 dep2 acc ->
            tieBreaker k dep1 dep2
                |> Task.bind (\v -> Task.fmap (Dict.insert keyComparison k v) acc)
        )
        (\k dep -> Task.fmap (Dict.insert keyComparison k dep))
        deps1
        deps2
        (Task.pure Dict.empty)


noDups : k -> v -> v -> Task v
noDups _ _ _ =
    Task.throw Exit.DetailsHandEditedDependencies


allowEqualDups : k -> v -> v -> Task v
allowEqualDups _ v1 v2 =
    if v1 == v2 then
        Task.pure v1

    else
        Task.throw Exit.DetailsHandEditedDependencies



-- FORK


fork : (a -> Encode.Value) -> IO a -> IO (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> IO.bind
            (\mvar ->
                Utils.forkIO (IO.bind (Utils.putMVar encoder mvar) work)
                    |> IO.fmap (\_ -> mvar)
            )



-- VERIFY DEPENDENCIES


verifyDependencies : Env -> File.Time -> ValidOutline -> Dict Pkg.Name Solver.Details -> Dict Pkg.Name a -> Task Details
verifyDependencies ((Env key scope root cache _ _ _) as env) time outline solution directDeps =
    Task.eio identity
        (Reporting.report key (Reporting.DStart (Dict.size solution))
            |> IO.bind (\_ -> Utils.newEmptyMVar)
            |> IO.bind
                (\mvar ->
                    Stuff.withRegistryLock cache
                        (Utils.mapTraverseWithKey Pkg.compareName (\k v -> fork depEncoder (verifyDep env mvar solution k v)) solution)
                        |> IO.bind
                            (\mvars ->
                                Utils.putMVar dictNameMVarDepEncoder mvar mvars
                                    |> IO.bind
                                        (\_ ->
                                            Utils.mapTraverse Pkg.compareName (Utils.readMVar depDecoder) mvars
                                                |> IO.bind
                                                    (\deps ->
                                                        case Utils.sequenceDictResult Pkg.compareName deps of
                                                            Err _ ->
                                                                Stuff.getElmHome
                                                                    |> IO.fmap
                                                                        (\home ->
                                                                            Err
                                                                                (Exit.DetailsBadDeps home
                                                                                    (List.filterMap identity (Utils.eitherLefts (Dict.values deps)))
                                                                                )
                                                                        )

                                                            Ok artifacts ->
                                                                let
                                                                    objs =
                                                                        Dict.foldr (\_ -> addObjects) Opt.empty artifacts

                                                                    ifaces =
                                                                        Dict.foldr (addInterfaces directDeps) Dict.empty artifacts

                                                                    foreigns =
                                                                        Dict.map (\_ -> OneOrMore.destruct Foreign) (Dict.foldr gatherForeigns Dict.empty (Dict.intersection artifacts directDeps))

                                                                    details =
                                                                        Details time outline 0 Dict.empty foreigns (ArtifactsFresh ifaces objs)
                                                                in
                                                                BW.writeBinary Opt.globalGraphEncoder scope (Stuff.objects root) objs
                                                                    |> IO.bind (\_ -> BW.writeBinary interfacesEncoder scope (Stuff.interfaces root) ifaces)
                                                                    |> IO.bind (\_ -> BW.writeBinary detailsEncoder scope (Stuff.details root) details)
                                                                    |> IO.fmap (\_ -> Ok details)
                                                    )
                                        )
                            )
                )
        )


addObjects : Artifacts -> Opt.GlobalGraph -> Opt.GlobalGraph
addObjects (Artifacts _ objs) graph =
    Opt.addGlobalGraph objs graph


addInterfaces : Dict Pkg.Name a -> Pkg.Name -> Artifacts -> Interfaces -> Interfaces
addInterfaces directDeps pkg (Artifacts ifaces _) dependencyInterfaces =
    Dict.union ModuleName.compareCanonical
        dependencyInterfaces
        (Dict.fromList ModuleName.compareCanonical
            (List.map (Tuple.mapFirst (ModuleName.Canonical pkg))
                (Dict.toList
                    (if Dict.member pkg directDeps then
                        ifaces

                     else
                        Dict.map (\_ -> I.privatize) ifaces
                    )
                )
            )
        )


gatherForeigns : Pkg.Name -> Artifacts -> Dict ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name) -> Dict ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name)
gatherForeigns pkg (Artifacts ifaces _) foreigns =
    let
        isPublic di =
            case di of
                I.Public _ ->
                    Just (OneOrMore.one pkg)

                I.Private _ _ _ ->
                    Nothing
    in
    Utils.mapUnionWith compare OneOrMore.more foreigns (Utils.mapMapMaybe compare isPublic ifaces)



-- VERIFY DEPENDENCY


type Artifacts
    = Artifacts (Dict ModuleName.Raw I.DependencyInterface) Opt.GlobalGraph


type alias Dep =
    Result (Maybe Exit.DetailsBadDep) Artifacts


verifyDep : Env -> MVar (Dict Pkg.Name (MVar Dep)) -> Dict Pkg.Name Solver.Details -> Pkg.Name -> Solver.Details -> IO Dep
verifyDep (Env key _ _ cache manager _ _) depsMVar solution pkg ((Solver.Details vsn directDeps) as details) =
    let
        fingerprint =
            Utils.mapIntersectionWith Pkg.compareName (\(Solver.Details v _) _ -> v) solution directDeps
    in
    Utils.dirDoesDirectoryExist (Stuff.package cache pkg vsn ++ "/src")
        |> IO.bind
            (\exists ->
                if exists then
                    Reporting.report key Reporting.DCached
                        |> IO.bind
                            (\_ ->
                                File.readBinary artifactCacheDecoder (Stuff.package cache pkg vsn ++ "/artifacts.json")
                                    |> IO.bind
                                        (\maybeCache ->
                                            case maybeCache of
                                                Nothing ->
                                                    build key cache depsMVar pkg details fingerprint EverySet.empty

                                                Just (ArtifactCache fingerprints artifacts) ->
                                                    if EverySet.member fingerprint fingerprints then
                                                        IO.fmap (\_ -> Ok artifacts) (Reporting.report key Reporting.DBuilt)

                                                    else
                                                        build key cache depsMVar pkg details fingerprint fingerprints
                                        )
                            )

                else
                    Reporting.report key Reporting.DRequested
                        |> IO.bind
                            (\_ ->
                                downloadPackage cache manager pkg vsn
                                    |> IO.bind
                                        (\result ->
                                            case result of
                                                Err problem ->
                                                    Reporting.report key (Reporting.DFailed pkg vsn)
                                                        |> IO.fmap (\_ -> Err (Just (Exit.BD_BadDownload pkg vsn problem)))

                                                Ok () ->
                                                    Reporting.report key (Reporting.DReceived pkg vsn)
                                                        |> IO.bind (\_ -> build key cache depsMVar pkg details fingerprint EverySet.empty)
                                        )
                            )
            )



-- ARTIFACT CACHE


type ArtifactCache
    = ArtifactCache (EverySet Fingerprint) Artifacts


type alias Fingerprint =
    Dict Pkg.Name V.Version



-- BUILD


build : Reporting.DKey -> Stuff.PackageCache -> MVar (Dict Pkg.Name (MVar Dep)) -> Pkg.Name -> Solver.Details -> Fingerprint -> EverySet Fingerprint -> IO Dep
build key cache depsMVar pkg (Solver.Details vsn _) f fs =
    Outline.read (Stuff.package cache pkg vsn)
        |> IO.bind
            (\eitherOutline ->
                case eitherOutline of
                    Err _ ->
                        Reporting.report key Reporting.DBroken
                            |> IO.fmap (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn f)))

                    Ok (Outline.App _) ->
                        Reporting.report key Reporting.DBroken
                            |> IO.fmap (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn f)))

                    Ok (Outline.Pkg (Outline.PkgOutline _ _ _ _ exposed deps _ _)) ->
                        Utils.readMVar dictPkgNameMVarDepDecoder depsMVar
                            |> IO.bind
                                (\allDeps ->
                                    Utils.mapTraverse Pkg.compareName (Utils.readMVar depDecoder) (Dict.intersection allDeps deps)
                                        |> IO.bind
                                            (\directDeps ->
                                                case Utils.sequenceDictResult Pkg.compareName directDeps of
                                                    Err _ ->
                                                        Reporting.report key Reporting.DBroken
                                                            |> IO.fmap (\_ -> Err Nothing)

                                                    Ok directArtifacts ->
                                                        let
                                                            src =
                                                                Stuff.package cache pkg vsn ++ "/src"

                                                            foreignDeps =
                                                                gatherForeignInterfaces directArtifacts

                                                            exposedDict =
                                                                Utils.mapFromKeys compare (\_ -> ()) (Outline.flattenExposed exposed)
                                                        in
                                                        getDocsStatus cache pkg vsn
                                                            |> IO.bind
                                                                (\docsStatus ->
                                                                    Utils.newEmptyMVar
                                                                        |> IO.bind
                                                                            (\mvar ->
                                                                                Utils.mapTraverseWithKey compare (always << fork (E.maybe statusEncoder) << crawlModule foreignDeps mvar pkg src docsStatus) exposedDict
                                                                                    |> IO.bind
                                                                                        (\mvars ->
                                                                                            Utils.putMVar statusDictEncoder mvar mvars
                                                                                                |> IO.bind (\_ -> Utils.dictMapM_ (Utils.readMVar (Decode.maybe statusDecoder)) mvars)
                                                                                                |> IO.bind (\_ -> IO.bind (Utils.mapTraverse compare (Utils.readMVar (Decode.maybe statusDecoder))) (Utils.readMVar statusDictDecoder mvar))
                                                                                                |> IO.bind
                                                                                                    (\maybeStatuses ->
                                                                                                        case Utils.sequenceDictMaybe compare maybeStatuses of
                                                                                                            Nothing ->
                                                                                                                Reporting.report key Reporting.DBroken
                                                                                                                    |> IO.fmap (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn f)))

                                                                                                            Just statuses ->
                                                                                                                Utils.newEmptyMVar
                                                                                                                    |> IO.bind
                                                                                                                        (\rmvar ->
                                                                                                                            Utils.mapTraverse compare (fork (E.maybe dResultEncoder) << compile pkg rmvar) statuses
                                                                                                                                |> IO.bind
                                                                                                                                    (\rmvars ->
                                                                                                                                        Utils.putMVar dictRawMVarMaybeDResultEncoder rmvar rmvars
                                                                                                                                            |> IO.bind (\_ -> Utils.mapTraverse compare (Utils.readMVar (Decode.maybe dResultDecoder)) rmvars)
                                                                                                                                            |> IO.bind
                                                                                                                                                (\maybeResults ->
                                                                                                                                                    case Utils.sequenceDictMaybe compare maybeResults of
                                                                                                                                                        Nothing ->
                                                                                                                                                            Reporting.report key Reporting.DBroken
                                                                                                                                                                |> IO.fmap (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn f)))

                                                                                                                                                        Just results ->
                                                                                                                                                            let
                                                                                                                                                                path =
                                                                                                                                                                    Stuff.package cache pkg vsn ++ "/artifacts.json"

                                                                                                                                                                ifaces =
                                                                                                                                                                    gatherInterfaces exposedDict results

                                                                                                                                                                objects =
                                                                                                                                                                    gatherObjects results

                                                                                                                                                                artifacts =
                                                                                                                                                                    Artifacts ifaces objects

                                                                                                                                                                fingerprints =
                                                                                                                                                                    EverySet.insert (\_ _ -> EQ) f fs
                                                                                                                                                            in
                                                                                                                                                            writeDocs cache pkg vsn docsStatus results
                                                                                                                                                                |> IO.bind (\_ -> File.writeBinary artifactCacheEncoder path (ArtifactCache fingerprints artifacts))
                                                                                                                                                                |> IO.bind (\_ -> Reporting.report key Reporting.DBuilt)
                                                                                                                                                                |> IO.fmap (\_ -> Ok artifacts)
                                                                                                                                                )
                                                                                                                                    )
                                                                                                                        )
                                                                                                    )
                                                                                        )
                                                                            )
                                                                )
                                            )
                                )
            )



-- GATHER


gatherObjects : Dict ModuleName.Raw DResult -> Opt.GlobalGraph
gatherObjects results =
    Dict.foldr addLocalGraph Opt.empty results


addLocalGraph : ModuleName.Raw -> DResult -> Opt.GlobalGraph -> Opt.GlobalGraph
addLocalGraph name status graph =
    case status of
        RLocal _ objs _ ->
            Opt.addLocalGraph objs graph

        RForeign _ ->
            graph

        RKernelLocal cs ->
            Opt.addKernel (Name.getKernel name) cs graph

        RKernelForeign ->
            graph


gatherInterfaces : Dict ModuleName.Raw () -> Dict ModuleName.Raw DResult -> Dict ModuleName.Raw I.DependencyInterface
gatherInterfaces exposed artifacts =
    let
        onLeft _ _ _ =
            crash "compiler bug manifesting in Elm.Details.gatherInterfaces"

        onBoth k () iface =
            toLocalInterface I.public iface
                |> Maybe.map (Dict.insert compare k)
                |> Maybe.withDefault identity

        onRight k iface =
            toLocalInterface I.private iface
                |> Maybe.map (Dict.insert compare k)
                |> Maybe.withDefault identity
    in
    Dict.merge onLeft onBoth onRight exposed artifacts Dict.empty


toLocalInterface : (I.Interface -> a) -> DResult -> Maybe a
toLocalInterface func result =
    case result of
        RLocal iface _ _ ->
            Just (func iface)

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- GATHER FOREIGN INTERFACES


type ForeignInterface
    = ForeignAmbiguous
    | ForeignSpecific I.Interface


gatherForeignInterfaces : Dict Pkg.Name Artifacts -> Dict ModuleName.Raw ForeignInterface
gatherForeignInterfaces directArtifacts =
    let
        finalize : I.Interface -> List I.Interface -> ForeignInterface
        finalize i is =
            case is of
                [] ->
                    ForeignSpecific i

                _ :: _ ->
                    ForeignAmbiguous

        gather : Pkg.Name -> Artifacts -> Dict ModuleName.Raw (OneOrMore.OneOrMore I.Interface) -> Dict ModuleName.Raw (OneOrMore.OneOrMore I.Interface)
        gather _ (Artifacts ifaces _) buckets =
            Utils.mapUnionWith compare OneOrMore.more buckets (Utils.mapMapMaybe compare isPublic ifaces)

        isPublic : I.DependencyInterface -> Maybe (OneOrMore.OneOrMore I.Interface)
        isPublic di =
            case di of
                I.Public iface ->
                    Just (OneOrMore.one iface)

                I.Private _ _ _ ->
                    Nothing
    in
    Dict.map (\_ -> OneOrMore.destruct finalize) <|
        Dict.foldr gather Dict.empty directArtifacts



-- CRAWL


type alias StatusDict =
    Dict ModuleName.Raw (MVar (Maybe Status))


type Status
    = SLocal DocsStatus (Dict ModuleName.Raw ()) Src.Module
    | SForeign I.Interface
    | SKernelLocal (List Kernel.Chunk)
    | SKernelForeign


crawlModule : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> IO (Maybe Status)
crawlModule foreignDeps mvar pkg src docsStatus name =
    let
        path =
            Utils.fpForwardSlash src (Utils.fpAddExtension (ModuleName.toFilePath name) "elm")
    in
    File.exists path
        |> IO.bind
            (\exists ->
                case Dict.get name foreignDeps of
                    Just ForeignAmbiguous ->
                        IO.pure Nothing

                    Just (ForeignSpecific iface) ->
                        if exists then
                            IO.pure Nothing

                        else
                            IO.pure (Just (SForeign iface))

                    Nothing ->
                        if exists then
                            crawlFile foreignDeps mvar pkg src docsStatus name path

                        else if Pkg.isKernel pkg && Name.isKernel name then
                            crawlKernel foreignDeps mvar pkg src name

                        else
                            IO.pure Nothing
            )


crawlFile : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> IO (Maybe Status)
crawlFile foreignDeps mvar pkg src docsStatus expectedName path =
    File.readUtf8 path
        |> IO.bind
            (\bytes ->
                case Parse.fromByteString (Parse.Package pkg) bytes of
                    Ok ((Src.Module (Just (A.At _ actualName)) _ _ imports _ _ _ _ _) as modul) ->
                        if expectedName == actualName then
                            crawlImports foreignDeps mvar pkg src imports
                                |> IO.fmap (\deps -> Just (SLocal docsStatus deps modul))

                        else
                            IO.pure Nothing

                    _ ->
                        IO.pure Nothing
            )


crawlImports : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> List Src.Import -> IO (Dict ModuleName.Raw ())
crawlImports foreignDeps mvar pkg src imports =
    Utils.takeMVar statusDictDecoder mvar
        |> IO.bind
            (\statusDict ->
                let
                    deps =
                        Dict.fromList compare (List.map (\i -> ( Src.getImportName i, () )) imports)

                    news =
                        Dict.diff deps statusDict
                in
                Utils.mapTraverseWithKey compare (always << fork (E.maybe statusEncoder) << crawlModule foreignDeps mvar pkg src DocsNotNeeded) news
                    |> IO.bind
                        (\mvars ->
                            Utils.putMVar statusDictEncoder mvar (Dict.union compare mvars statusDict)
                                |> IO.bind (\_ -> Utils.dictMapM_ (Utils.readMVar (Decode.maybe statusDecoder)) mvars)
                                |> IO.fmap (\_ -> deps)
                        )
            )


crawlKernel : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> ModuleName.Raw -> IO (Maybe Status)
crawlKernel foreignDeps mvar pkg src name =
    let
        path =
            Utils.fpForwardSlash src (Utils.fpAddExtension (ModuleName.toFilePath name) "js")
    in
    File.exists path
        |> IO.bind
            (\exists ->
                if exists then
                    File.readUtf8 path
                        |> IO.bind
                            (\bytes ->
                                case Kernel.fromByteString pkg (Utils.mapMapMaybe compare getDepHome foreignDeps) bytes of
                                    Nothing ->
                                        IO.pure Nothing

                                    Just (Kernel.Content imports chunks) ->
                                        crawlImports foreignDeps mvar pkg src imports
                                            |> IO.fmap (\_ -> Just (SKernelLocal chunks))
                            )

                else
                    IO.pure (Just SKernelForeign)
            )


getDepHome : ForeignInterface -> Maybe Pkg.Name
getDepHome fi =
    case fi of
        ForeignSpecific (I.Interface pkg _ _ _ _) ->
            Just pkg

        ForeignAmbiguous ->
            Nothing



-- COMPILE


type DResult
    = RLocal I.Interface Opt.LocalGraph (Maybe Docs.Module)
    | RForeign I.Interface
    | RKernelLocal (List Kernel.Chunk)
    | RKernelForeign


compile : Pkg.Name -> MVar (Dict ModuleName.Raw (MVar (Maybe DResult))) -> Status -> IO (Maybe DResult)
compile pkg mvar status =
    case status of
        SLocal docsStatus deps modul ->
            Utils.readMVar moduleNameRawMVarMaybeDResultDecoder mvar
                |> IO.bind
                    (\resultsDict ->
                        Utils.mapTraverse compare (Utils.readMVar (Decode.maybe dResultDecoder)) (Dict.intersection resultsDict deps)
                            |> IO.bind
                                (\maybeResults ->
                                    case Utils.sequenceDictMaybe compare maybeResults of
                                        Just results ->
                                            Compile.compile pkg (Utils.mapMapMaybe compare getInterface results) modul
                                                |> IO.fmap
                                                    (\result ->
                                                        case result of
                                                            Err _ ->
                                                                Nothing

                                                            Ok (Compile.Artifacts canonical annotations objects) ->
                                                                let
                                                                    ifaces =
                                                                        I.fromModule pkg canonical annotations

                                                                    docs =
                                                                        makeDocs docsStatus canonical
                                                                in
                                                                Just (RLocal ifaces objects docs)
                                                    )

                                        Nothing ->
                                            IO.pure Nothing
                                )
                    )

        SForeign iface ->
            IO.pure (Just (RForeign iface))

        SKernelLocal chunks ->
            IO.pure (Just (RKernelLocal chunks))

        SKernelForeign ->
            IO.pure (Just RKernelForeign)


getInterface : DResult -> Maybe I.Interface
getInterface result =
    case result of
        RLocal iface _ _ ->
            Just iface

        RForeign iface ->
            Just iface

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- MAKE DOCS


type DocsStatus
    = DocsNeeded
    | DocsNotNeeded


getDocsStatus : Stuff.PackageCache -> Pkg.Name -> V.Version -> IO DocsStatus
getDocsStatus cache pkg vsn =
    File.exists (Stuff.package cache pkg vsn ++ "/docs.json")
        |> IO.fmap
            (\exists ->
                if exists then
                    DocsNotNeeded

                else
                    DocsNeeded
            )


makeDocs : DocsStatus -> Can.Module -> Maybe Docs.Module
makeDocs status modul =
    case status of
        DocsNeeded ->
            case Docs.fromModule modul of
                Ok docs ->
                    Just docs

                Err _ ->
                    Nothing

        DocsNotNeeded ->
            Nothing


writeDocs : Stuff.PackageCache -> Pkg.Name -> V.Version -> DocsStatus -> Dict ModuleName.Raw DResult -> IO ()
writeDocs cache pkg vsn status results =
    case status of
        DocsNeeded ->
            E.writeUgly (Stuff.package cache pkg vsn ++ "/docs.json")
                (Docs.encode (Utils.mapMapMaybe compare toDocs results))

        DocsNotNeeded ->
            IO.pure ()


toDocs : DResult -> Maybe Docs.Module
toDocs result =
    case result of
        RLocal _ _ docs ->
            docs

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- DOWNLOAD PACKAGE


downloadPackage : Stuff.PackageCache -> Http.Manager -> Pkg.Name -> V.Version -> IO (Result Exit.PackageProblem ())
downloadPackage cache manager pkg vsn =
    let
        url =
            Website.metadata pkg vsn "endpoint.json"
    in
    Http.get manager url [] identity (IO.pure << Ok)
        |> IO.bind
            (\eitherByteString ->
                case eitherByteString of
                    Err err ->
                        IO.pure (Err (Exit.PP_BadEndpointRequest err))

                    Ok byteString ->
                        case D.fromByteString endpointDecoder byteString of
                            Err _ ->
                                IO.pure (Err (Exit.PP_BadEndpointContent url))

                            Ok ( endpoint, expectedHash ) ->
                                Http.getArchive manager endpoint Exit.PP_BadArchiveRequest (Exit.PP_BadArchiveContent endpoint) <|
                                    \( sha, archive ) ->
                                        -- TODO (IMPORTANT) if expectedHash == Http.shaToChars sha then
                                        IO.fmap Ok (File.writePackage (Stuff.package cache pkg vsn) archive)
             -- else
             --     IO.pure (Err (Exit.PP_BadArchiveHash endpoint expectedHash (Http.shaToChars sha)))
            )


endpointDecoder : D.Decoder e ( String, String )
endpointDecoder =
    D.field "url" D.string
        |> D.bind
            (\url ->
                D.field "hash" D.string
                    |> D.fmap (\hash -> ( url, hash ))
            )



-- ENCODERS and DECODERS


detailsEncoder : Details -> Encode.Value
detailsEncoder (Details oldTime outline buildID locals foreigns extras) =
    Encode.object
        [ ( "type", Encode.string "Details" )
        , ( "oldTime", File.timeEncoder oldTime )
        , ( "outline", validOutlineEncoder outline )
        , ( "buildID", Encode.int buildID )
        , ( "locals", E.assocListDict ModuleName.rawEncoder localEncoder locals )
        , ( "foreigns", E.assocListDict ModuleName.rawEncoder foreignEncoder foreigns )
        , ( "extras", extrasEncoder extras )
        ]


detailsDecoder : Decode.Decoder Details
detailsDecoder =
    Decode.map6 Details
        (Decode.field "oldTime" File.timeDecoder)
        (Decode.field "outline" validOutlineDecoder)
        (Decode.field "buildID" Decode.int)
        (Decode.field "locals" (D.assocListDict compare ModuleName.rawDecoder localDecoder))
        (Decode.field "foreigns" (D.assocListDict compare ModuleName.rawDecoder foreignDecoder))
        (Decode.field "extras" extrasDecoder)


interfacesEncoder : Interfaces -> Encode.Value
interfacesEncoder =
    E.assocListDict ModuleName.canonicalEncoder I.dependencyInterfaceEncoder


interfacesDecoder : Decode.Decoder Interfaces
interfacesDecoder =
    D.assocListDict ModuleName.compareCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder


resultRegistryProblemEnvEncoder : Result Exit.RegistryProblem Solver.Env -> Encode.Value
resultRegistryProblemEnvEncoder =
    E.result Exit.registryProblemEncoder Solver.envEncoder


resultRegistryProblemEnvDecoder : Decode.Decoder (Result Exit.RegistryProblem Solver.Env)
resultRegistryProblemEnvDecoder =
    D.result Exit.registryProblemDecoder Solver.envDecoder


depEncoder : Dep -> Encode.Value
depEncoder dep =
    E.result (E.maybe Exit.detailsBadDepEncoder) artifactsEncoder dep


depDecoder : Decode.Decoder Dep
depDecoder =
    D.result (Decode.maybe Exit.detailsBadDepDecoder) artifactsDecoder


artifactsEncoder : Artifacts -> Encode.Value
artifactsEncoder (Artifacts ifaces objects) =
    Encode.object
        [ ( "type", Encode.string "Artifacts" )
        , ( "ifaces", E.assocListDict ModuleName.rawEncoder I.dependencyInterfaceEncoder ifaces )
        , ( "objects", Opt.globalGraphEncoder objects )
        ]


artifactsDecoder : Decode.Decoder Artifacts
artifactsDecoder =
    Decode.map2 Artifacts
        (Decode.field "ifaces" (D.assocListDict compare ModuleName.rawDecoder I.dependencyInterfaceDecoder))
        (Decode.field "objects" Opt.globalGraphDecoder)


dictNameMVarDepEncoder : Dict Pkg.Name (MVar Dep) -> Encode.Value
dictNameMVarDepEncoder =
    E.assocListDict Pkg.nameEncoder Utils.mVarEncoder


artifactCacheEncoder : ArtifactCache -> Encode.Value
artifactCacheEncoder (ArtifactCache fingerprints artifacts) =
    Encode.object
        [ ( "type", Encode.string "ArtifactCache" )
        , ( "fingerprints", E.everySet fingerprintEncoder fingerprints )
        , ( "artifacts", artifactsEncoder artifacts )
        ]


artifactCacheDecoder : Decode.Decoder ArtifactCache
artifactCacheDecoder =
    Decode.map2 ArtifactCache
        (Decode.field "fingerprints" (D.everySet (\_ _ -> EQ) fingerprintDecoder))
        (Decode.field "artifacts" artifactsDecoder)


dictPkgNameMVarDepDecoder : Decode.Decoder (Dict Pkg.Name (MVar Dep))
dictPkgNameMVarDepDecoder =
    D.assocListDict Pkg.compareName Pkg.nameDecoder Utils.mVarDecoder


statusEncoder : Status -> Encode.Value
statusEncoder status =
    case status of
        SLocal docsStatus deps modul ->
            Encode.object
                [ ( "type", Encode.string "SLocal" )
                , ( "docsStatus", docsStatusEncoder docsStatus )
                , ( "deps", E.assocListDict ModuleName.rawEncoder (\_ -> Encode.object []) deps )
                , ( "modul", Src.moduleEncoder modul )
                ]

        SForeign iface ->
            Encode.object
                [ ( "type", Encode.string "SForeign" )
                , ( "iface", I.interfaceEncoder iface )
                ]

        SKernelLocal chunks ->
            Encode.object
                [ ( "type", Encode.string "SKernelLocal" )
                , ( "chunks", Encode.list Kernel.chunkEncoder chunks )
                ]

        SKernelForeign ->
            Encode.object
                [ ( "type", Encode.string "SKernelForeign" )
                ]


statusDecoder : Decode.Decoder Status
statusDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "SLocal" ->
                        Decode.map3 SLocal
                            (Decode.field "docsStatus" docsStatusDecoder)
                            (Decode.field "deps" (D.assocListDict compare ModuleName.rawDecoder (Decode.succeed ())))
                            (Decode.field "modul" Src.moduleDecoder)

                    "SForeign" ->
                        Decode.map SForeign (Decode.field "iface" I.interfaceDecoder)

                    "SKernelLocal" ->
                        Decode.map SKernelLocal (Decode.field "chunks" (Decode.list Kernel.chunkDecoder))

                    "SKernelForeign" ->
                        Decode.succeed SKernelForeign

                    _ ->
                        Decode.fail ("Failed to decode Status' type: " ++ type_)
            )


dictRawMVarMaybeDResultEncoder : Dict ModuleName.Raw (MVar (Maybe DResult)) -> Encode.Value
dictRawMVarMaybeDResultEncoder =
    E.assocListDict ModuleName.rawEncoder Utils.mVarEncoder


moduleNameRawMVarMaybeDResultDecoder : Decode.Decoder (Dict ModuleName.Raw (MVar (Maybe DResult)))
moduleNameRawMVarMaybeDResultDecoder =
    D.assocListDict compare ModuleName.rawDecoder Utils.mVarDecoder


dResultEncoder : DResult -> Encode.Value
dResultEncoder dResult =
    case dResult of
        RLocal ifaces objects docs ->
            Encode.object
                [ ( "type", Encode.string "RLocal" )
                , ( "ifaces", I.interfaceEncoder ifaces )
                , ( "objects", Opt.localGraphEncoder objects )
                , ( "docs", E.maybe Docs.jsonModuleEncoder docs )
                ]

        RForeign iface ->
            Encode.object
                [ ( "type", Encode.string "RForeign" )
                , ( "iface", I.interfaceEncoder iface )
                ]

        RKernelLocal chunks ->
            Encode.object
                [ ( "type", Encode.string "RKernelLocal" )
                , ( "chunks", Encode.list Kernel.chunkEncoder chunks )
                ]

        RKernelForeign ->
            Encode.object
                [ ( "type", Encode.string "RKernelForeign" )
                ]


dResultDecoder : Decode.Decoder DResult
dResultDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "RLocal" ->
                        Decode.map3 RLocal
                            (Decode.field "ifaces" I.interfaceDecoder)
                            (Decode.field "objects" Opt.localGraphDecoder)
                            (Decode.field "docs" (Decode.maybe Docs.jsonModuleDecoder))

                    "RForeign" ->
                        Decode.map RForeign (Decode.field "iface" I.interfaceDecoder)

                    "RKernelLocal" ->
                        Decode.map RKernelLocal (Decode.field "chunks" (Decode.list Kernel.chunkDecoder))

                    "RKernelForeign" ->
                        Decode.succeed RKernelForeign

                    _ ->
                        Decode.fail ("Failed to decode DResult's type: " ++ type_)
            )


statusDictEncoder : StatusDict -> Encode.Value
statusDictEncoder statusDict =
    E.assocListDict ModuleName.rawEncoder Utils.mVarEncoder statusDict


statusDictDecoder : Decode.Decoder StatusDict
statusDictDecoder =
    D.assocListDict compare ModuleName.rawDecoder Utils.mVarDecoder


localEncoder : Local -> Encode.Value
localEncoder (Local path time deps hasMain lastChange lastCompile) =
    Encode.object
        [ ( "type", Encode.string "Local" )
        , ( "path", Encode.string path )
        , ( "time", File.timeEncoder time )
        , ( "deps", Encode.list ModuleName.rawEncoder deps )
        , ( "hasMain", Encode.bool hasMain )
        , ( "lastChange", Encode.int lastChange )
        , ( "lastCompile", Encode.int lastCompile )
        ]


localDecoder : Decode.Decoder Local
localDecoder =
    Decode.map6 Local
        (Decode.field "path" Decode.string)
        (Decode.field "time" File.timeDecoder)
        (Decode.field "deps" (Decode.list ModuleName.rawDecoder))
        (Decode.field "hasMain" Decode.bool)
        (Decode.field "lastChange" Decode.int)
        (Decode.field "lastCompile" Decode.int)


validOutlineEncoder : ValidOutline -> Encode.Value
validOutlineEncoder validOutline =
    case validOutline of
        ValidApp srcDirs ->
            Encode.object
                [ ( "type", Encode.string "ValidApp" )
                , ( "srcDirs", E.nonempty Outline.srcDirEncoder srcDirs )
                ]

        ValidPkg pkg exposedList exactDeps ->
            Encode.object
                [ ( "type", Encode.string "ValidPkg" )
                , ( "pkg", Pkg.nameEncoder pkg )
                , ( "exposedList", Encode.list ModuleName.rawEncoder exposedList )
                , ( "exactDeps", E.assocListDict Pkg.nameEncoder V.versionEncoder exactDeps )
                ]


validOutlineDecoder : Decode.Decoder ValidOutline
validOutlineDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "ValidApp" ->
                        Decode.map ValidApp (Decode.field "srcDirs" (D.nonempty Outline.srcDirDecoder))

                    "ValidPkg" ->
                        Decode.map3 ValidPkg
                            (Decode.field "pkg" Pkg.nameDecoder)
                            (Decode.field "exposedList" (Decode.list ModuleName.rawDecoder))
                            (Decode.field "exactDeps" (D.assocListDict Pkg.compareName Pkg.nameDecoder V.versionDecoder))

                    _ ->
                        Decode.fail ("Failed to decode ValidOutline's type: " ++ type_)
            )


foreignEncoder : Foreign -> Encode.Value
foreignEncoder (Foreign dep deps) =
    Encode.object
        [ ( "type", Encode.string "Foreign" )
        , ( "dep", Pkg.nameEncoder dep )
        , ( "deps", Encode.list Pkg.nameEncoder deps )
        ]


foreignDecoder : Decode.Decoder Foreign
foreignDecoder =
    Decode.map2 Foreign
        (Decode.field "dep" Pkg.nameDecoder)
        (Decode.field "deps" (Decode.list Pkg.nameDecoder))


extrasEncoder : Extras -> Encode.Value
extrasEncoder extras =
    case extras of
        ArtifactsCached ->
            Encode.object
                [ ( "type", Encode.string "ArtifactsCached" )
                ]

        ArtifactsFresh ifaces objs ->
            Encode.object
                [ ( "type", Encode.string "ArtifactsFresh" )
                , ( "ifaces", interfacesEncoder ifaces )
                , ( "objs", Opt.globalGraphEncoder objs )
                ]


extrasDecoder : Decode.Decoder Extras
extrasDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "ArtifactsCached" ->
                        Decode.succeed ArtifactsCached

                    "ArtifactsFresh" ->
                        Decode.map2 ArtifactsFresh
                            (Decode.field "ifaces" interfacesDecoder)
                            (Decode.field "objs" Opt.globalGraphDecoder)

                    _ ->
                        Decode.fail ("Failed to decode Extras' type: " ++ type_)
            )


fingerprintEncoder : Fingerprint -> Encode.Value
fingerprintEncoder =
    E.assocListDict Pkg.nameEncoder V.versionEncoder


fingerprintDecoder : Decode.Decoder Fingerprint
fingerprintDecoder =
    D.assocListDict Pkg.compareName Pkg.nameDecoder V.versionDecoder


docsStatusEncoder : DocsStatus -> Encode.Value
docsStatusEncoder docsStatus =
    case docsStatus of
        DocsNeeded ->
            Encode.string "DocsNeeded"

        DocsNotNeeded ->
            Encode.string "DocsNotNeeded"


docsStatusDecoder : Decode.Decoder DocsStatus
docsStatusDecoder =
    Decode.string
        |> Decode.andThen
            (\str ->
                case str of
                    "DocsNeeded" ->
                        Decode.succeed DocsNeeded

                    "DocsNotNeeded" ->
                        Decode.succeed DocsNotNeeded

                    _ ->
                        Decode.fail ("Unknown DocsStatus: " ++ str)
            )
