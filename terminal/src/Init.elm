module Init exposing (run)

import Data.IO as IO exposing (IO)
import Data.Map as Dict exposing (Dict)
import Data.NonEmptyList as NE
import Deps.Solver as Solver
import Elm.Constraint as Con
import Elm.Outline as Outline
import Elm.Package as Pkg
import Elm.Version as V
import Reporting
import Reporting.Doc as D
import Reporting.Exit as Exit
import Utils.Main as Utils



-- RUN


run : IO ()
run =
    Reporting.attempt Exit.initToReport <|
        (Utils.dirDoesFileExist "elm.json"
            |> IO.bind
                (\exists ->
                    if exists then
                        IO.pure (Err Exit.InitAlreadyExists)

                    else
                        Reporting.ask question
                            |> IO.bind
                                (\approved ->
                                    if approved then
                                        init

                                    else
                                        Utils.putStrLn "Okay, I did not make any changes!"
                                            |> IO.fmap (\_ -> Ok ())
                                )
                )
        )


question : D.Doc
question =
    D.stack
        [ D.fillSep
            [ D.fromChars "Hello!"
            , D.fromChars "Elm"
            , D.fromChars "projects"
            , D.fromChars "always"
            , D.fromChars "start"
            , D.fromChars "with"
            , D.fromChars "an"
            , D.green (D.fromChars "elm.json")
            , D.fromChars "file."
            , D.fromChars "I"
            , D.fromChars "can"
            , D.fromChars "create"
            , D.fromChars "them!"
            ]
        , D.reflow "Now you may be wondering, what will be in this file? How do I add Elm files to my project? How do I see it in the browser? How will my code grow? Do I need more directories? What about tests? Etc."
        , D.fillSep
            [ D.fromChars "Check"
            , D.fromChars "out"
            , D.cyan (D.fromChars (D.makeLink "init"))
            , D.fromChars "for"
            , D.fromChars "all"
            , D.fromChars "the"
            , D.fromChars "answers!"
            ]
        , D.fromChars "Knowing all that, would you like me to create an elm.json file now? [Y/n]: "
        ]



-- INIT


init : IO (Result Exit.Init ())
init =
    Solver.initEnv
        |> IO.bind
            (\eitherEnv ->
                case eitherEnv of
                    Err problem ->
                        IO.pure (Err (Exit.InitRegistryProblem problem))

                    Ok (Solver.Env cache _ connection registry) ->
                        Solver.verify cache connection registry defaults
                            |> IO.bind
                                (\result ->
                                    case result of
                                        Solver.SolverErr exit ->
                                            IO.pure (Err (Exit.InitSolverProblem exit))

                                        Solver.NoSolution ->
                                            IO.pure (Err (Exit.InitNoSolution (Dict.keys defaults)))

                                        Solver.NoOfflineSolution ->
                                            IO.pure (Err (Exit.InitNoOfflineSolution (Dict.keys defaults)))

                                        Solver.SolverOk details ->
                                            let
                                                solution =
                                                    Dict.map (\_ (Solver.Details vsn _) -> vsn) details

                                                directs =
                                                    Dict.intersection solution defaults

                                                indirects =
                                                    Dict.diff solution defaults
                                            in
                                            Utils.dirCreateDirectoryIfMissing True "src"
                                                |> IO.bind
                                                    (\_ ->
                                                        Outline.write "." <|
                                                            Outline.App <|
                                                                Outline.AppOutline V.compiler (NE.Nonempty (Outline.RelativeSrcDir "src") []) directs indirects Dict.empty Dict.empty
                                                    )
                                                |> IO.bind (\_ -> Utils.putStrLn "Okay, I created it. Now read that link!")
                                                |> IO.fmap (\_ -> Ok ())
                                )
            )


defaults : Dict Pkg.Name Con.Constraint
defaults =
    Dict.fromList Pkg.compareName
        [ ( Pkg.core, Con.anything )
        , ( Pkg.browser, Con.anything )
        , ( Pkg.html, Con.anything )
        ]
