module EveOnline.BotFrameworkSeparatingMemory exposing (..)

{-| A framework to build EVE Online bots and intel tools.
Features:

  - Read from the game client using Sanderling memory reading and parse the user interface from the memory reading (<https://github.com/Arcitectus/Sanderling>).
  - Play sounds.
  - Send mouse and keyboard input to the game client.
  - Parse the bot-settings and inform the user about the result.

The framework automatically selects an EVE Online client process and finishes the session when that process disappears.
When multiple game clients are open, the framework prioritizes the one with the topmost window. This approach helps users control which game client is picked by an app.

To learn more about developing for EVE Online, see the guide at <https://to.botlab.org/guide/developing-for-eve-online>

-}

import BotLab.BotInterface_To_Host_2023_02_06 as InterfaceToHost
import Common.DecisionPath
import Common.EffectOnWindow
import EveOnline.BotFramework
    exposing
        ( ReadingFromGameClient
        , ReadingFromGameClientMemory
        , ReadingFromGameClientScreenshot
        , SeeUndockingComplete
        , ShipModulesMemory
        , UIElement
        , UseContextMenuCascadeNode
        , asReadingFromGameClientMemory
        , cornersFromDisplayRegion
        , doesPointIntersectRegion
        , getModuleButtonTooltipFromModuleButton
        , growRegionOnAllSides
        , mouseClickOnUIElement
        , unpackContextMenuTreeToListOfActionsDependingOnReadings
        )
import EveOnline.ParseUserInterface
    exposing
        ( centerFromDisplayRegion
        , subtractRegionsFromRegion
        )
import List.Extra


type EndDecisionPathStructure
    = ContinueSession ContinueSessionStructure
    | FinishSession


type alias ContinueSessionStructure =
    { effectsOnGameClient : List Common.EffectOnWindow.EffectOnWindowStructure
    , millisecondsToNextReadingFromGameBase : Maybe Int
    , millisecondsToNextReadingFromGameModifierPercent : Int
    }


type alias DecisionPathNode =
    Common.DecisionPath.DecisionPathNode EndDecisionPathStructure


type alias UpdateMemoryContext =
    { timeInMilliseconds : Int
    , readingFromGameClient : ReadingFromGameClient
    , screenshot : ReadingFromGameClientScreenshot
    }


type alias StepDecisionContext botSettings botMemory =
    { eventContext : EveOnline.BotFramework.BotEventContext botSettings
    , readingFromGameClient : ReadingFromGameClient
    , screenshot : ReadingFromGameClientScreenshot
    , memory : botMemory
    , previousStepEffects : List Common.EffectOnWindow.EffectOnWindowStructure
    , previousReadingsFromGameClient : List ReadingFromGameClientMemory
    , contextMenuCascadeLevel : Int
    }


type alias StateIncludingFramework botSettings botMemory =
    EveOnline.BotFramework.StateIncludingFramework botSettings (BotState botMemory)


type alias BotState botMemory =
    { botMemory : botMemory
    , lastStepEffects : List Common.EffectOnWindow.EffectOnWindowStructure
    , lastReadingsFromGameClient : List ReadingFromGameClientMemory
    }


type alias BotConfiguration botSettings botMemory =
    { parseBotSettings : String -> Result String botSettings
    , selectGameClientInstance : Maybe botSettings -> List EveOnline.BotFramework.GameClientProcessSummary -> Result String { selectedProcess : EveOnline.BotFramework.GameClientProcessSummary, report : List String }
    , updateMemoryForNewReadingFromGame : UpdateMemoryContext -> botMemory -> botMemory
    , statusTextFromDecisionContext : StepDecisionContext botSettings botMemory -> String
    , decideNextStep : StepDecisionContext botSettings botMemory -> DecisionPathNode
    }


type alias Rect2dStructure =
    { x : Int
    , y : Int
    , width : Int
    , height : Int
    }


millisecondsToNextReadingFromGameDefault : Int
millisecondsToNextReadingFromGameDefault =
    1500


initState : botMemory -> EveOnline.BotFramework.StateIncludingFramework botSettings (BotState botMemory)
initState botMemory =
    EveOnline.BotFramework.initState (initStateInBaseFramework botMemory)


initStateInBaseFramework : botMemory -> BotState botMemory
initStateInBaseFramework botMemory =
    { botMemory = botMemory
    , lastStepEffects = []
    , lastReadingsFromGameClient = []
    }


processEvent :
    BotConfiguration botSettings botMemory
    -> InterfaceToHost.BotEvent
    -> EveOnline.BotFramework.StateIncludingFramework botSettings (BotState botMemory)
    -> ( EveOnline.BotFramework.StateIncludingFramework botSettings (BotState botMemory), InterfaceToHost.BotEventResponse )
processEvent botConfiguration =
    EveOnline.BotFramework.processEvent
        { parseBotSettings = botConfiguration.parseBotSettings
        , selectGameClientInstance = botConfiguration.selectGameClientInstance
        , processEvent =
            processEventInBaseFramework
                { updateMemoryForNewReadingFromGame = botConfiguration.updateMemoryForNewReadingFromGame
                , statusTextFromDecisionContext = botConfiguration.statusTextFromDecisionContext
                , decideNextStep = botConfiguration.decideNextStep
                }
        }


processEventInBaseFramework :
    { updateMemoryForNewReadingFromGame : UpdateMemoryContext -> botMemory -> botMemory
    , statusTextFromDecisionContext : StepDecisionContext botSettings botMemory -> String
    , decideNextStep : StepDecisionContext botSettings botMemory -> DecisionPathNode
    }
    -> EveOnline.BotFramework.BotEventContext botSettings
    -> EveOnline.BotFramework.BotEvent
    -> BotState botMemory
    -> ( BotState botMemory, EveOnline.BotFramework.BotEventResponse )
processEventInBaseFramework config eventContext event stateBefore =
    case event of
        EveOnline.BotFramework.ReadingFromGameClientCompleted readingFromGameClient screenshot ->
            let
                updateMemoryContext =
                    { timeInMilliseconds = eventContext.timeInMilliseconds
                    , readingFromGameClient = readingFromGameClient
                    , screenshot = screenshot
                    }

                botMemory =
                    stateBefore.botMemory
                        |> config.updateMemoryForNewReadingFromGame updateMemoryContext

                lastReadingFromGameClientContextMenus =
                    stateBefore.lastReadingsFromGameClient
                        |> List.head
                        |> Maybe.map .contextMenus
                        |> Maybe.withDefault []

                contextMenuCascadeLevelAlreadyInPreviousReading =
                    List.map2
                        Tuple.pair
                        (List.reverse readingFromGameClient.contextMenus)
                        (List.reverse lastReadingFromGameClientContextMenus)
                        |> List.Extra.takeWhile
                            (\( inCurrent, inPrev ) ->
                                identifyingInfoFromContextMenu inCurrent == identifyingInfoFromContextMenu inPrev
                            )
                        |> List.length

                contextMenuCascadeLevel =
                    min (contextMenuCascadeLevelAlreadyInPreviousReading + 1)
                        (List.length readingFromGameClient.contextMenus)

                decisionContext =
                    { eventContext = eventContext
                    , memory = botMemory
                    , readingFromGameClient = readingFromGameClient
                    , screenshot = screenshot
                    , previousStepEffects = stateBefore.lastStepEffects
                    , previousReadingsFromGameClient = stateBefore.lastReadingsFromGameClient
                    , contextMenuCascadeLevel = contextMenuCascadeLevel
                    }

                ( decisionStagesDescriptions, decisionLeaf ) =
                    config.decideNextStep decisionContext
                        |> Common.DecisionPath.unpackToDecisionStagesDescriptionsAndLeaf

                effectsOnGameClientWindow =
                    case decisionLeaf of
                        ContinueSession act ->
                            act.effectsOnGameClient

                        FinishSession ->
                            []

                describeActivity =
                    decisionStagesDescriptions
                        |> List.indexedMap
                            (\decisionLevel -> (++) (("+" |> List.repeat (decisionLevel + 1) |> String.join "") ++ " "))
                        |> String.join "\n"

                statusText =
                    [ config.statusTextFromDecisionContext decisionContext
                    , describeActivity
                    ]
                        |> String.join "\n"

                readingFromGameClientMemory =
                    asReadingFromGameClientMemory readingFromGameClient
            in
            ( { botMemory = botMemory
              , lastStepEffects = effectsOnGameClientWindow
              , lastReadingsFromGameClient =
                    readingFromGameClientMemory
                        :: stateBefore.lastReadingsFromGameClient
                        |> List.take 3
              }
            , case decisionLeaf of
                ContinueSession continueSession ->
                    let
                        millisecondsToNextReadingFromGame =
                            ((continueSession.millisecondsToNextReadingFromGameModifierPercent + 100)
                                * (continueSession.millisecondsToNextReadingFromGameBase
                                    |> Maybe.withDefault millisecondsToNextReadingFromGameDefault
                                  )
                            )
                                // 100
                    in
                    EveOnline.BotFramework.ContinueSession
                        { effects = effectsOnGameClientWindow
                        , millisecondsToNextReadingFromGame = millisecondsToNextReadingFromGame
                        , statusText = statusText
                        }

                FinishSession ->
                    EveOnline.BotFramework.FinishSession { statusText = statusText }
            )


useContextMenuCascadeOnOverviewEntry :
    UseContextMenuCascadeNode
    -> EveOnline.ParseUserInterface.OverviewWindowEntry
    -> StepDecisionContext a b
    -> DecisionPathNode
useContextMenuCascadeOnOverviewEntry useContextMenu overviewEntry context =
    useContextMenuCascade
        ( "overview entry '" ++ (overviewEntry.objectName |> Maybe.withDefault "") ++ "'", overviewEntry.uiNode )
        useContextMenu
        context


useContextMenuCascadeOnListSurroundingsButton :
    UseContextMenuCascadeNode
    -> StepDecisionContext a b
    -> DecisionPathNode
useContextMenuCascadeOnListSurroundingsButton useContextMenu context =
    case context.readingFromGameClient.infoPanelContainer |> Maybe.andThen .infoPanelLocationInfo of
        Nothing ->
            Common.DecisionPath.describeBranch "I do not see the location info panel." askForHelpToGetUnstuck

        Just infoPanelLocationInfo ->
            useContextMenuCascade
                ( "surroundings button", infoPanelLocationInfo.listSurroundingsButton )
                useContextMenu
                context


useContextMenuCascade :
    ( String, UIElement )
    -> UseContextMenuCascadeNode
    -> StepDecisionContext a b
    -> DecisionPathNode
useContextMenuCascade ( initialUIElementName, initialUIElement ) useContextMenu context =
    let
        readingFromGameClient =
            context.readingFromGameClient

        beginCascade =
            let
                occludingRegionsWithSafetyMargin =
                    readingFromGameClient.contextMenus
                        |> List.map (.uiNode >> .totalDisplayRegion >> growRegionOnAllSides 2)

                regionsRemainingAfterOcclusion =
                    subtractRegionsFromRegion
                        { minuend = initialUIElement.totalDisplayRegion, subtrahend = occludingRegionsWithSafetyMargin }
            in
            case
                regionsRemainingAfterOcclusion
                    |> List.filter (\region -> 3 < region.width && 3 < region.height)
                    |> List.sortBy (\region -> negate (min region.width region.height))
                    |> List.head
            of
                Nothing ->
                    Common.DecisionPath.describeBranch
                        ("All of " ++ initialUIElementName ++ " is occluded by context menus.")
                        (Common.DecisionPath.describeBranch
                            "Click somewhere else to get rid of the occluding elements."
                            ({ x = 4, y = 4 }
                                |> Common.EffectOnWindow.effectsMouseClickAtLocation Common.EffectOnWindow.MouseButtonRight
                                |> decideActionForCurrentStep
                            )
                        )

                Just preferredRegion ->
                    Common.DecisionPath.describeBranch
                        ("Open context menu on " ++ initialUIElementName)
                        (preferredRegion
                            |> centerFromDisplayRegion
                            |> Common.EffectOnWindow.effectsMouseClickAtLocation Common.EffectOnWindow.MouseButtonRight
                            |> decideActionForCurrentStep
                        )
    in
    case context.previousReadingsFromGameClient |> List.take 3 |> List.reverse |> List.head of
        Nothing ->
            beginCascade

        Just previousReadingFromGameClient ->
            case List.reverse context.readingFromGameClient.contextMenus of
                [] ->
                    beginCascade

                cascadeFirstElement :: cascadeFollowingElements ->
                    let
                        cascadeFirstElementIsCloseToInitialUIElement =
                            cornersFromDisplayRegion cascadeFirstElement.uiNode.totalDisplayRegion
                                |> List.any
                                    (\corner ->
                                        doesPointIntersectRegion corner
                                            (initialUIElement.totalDisplayRegion |> growRegionOnAllSides 20)
                                    )
                    in
                    if not cascadeFirstElementIsCloseToInitialUIElement then
                        Common.DecisionPath.describeBranch "Existing cascade is too far away"
                            beginCascade

                    else if
                        (context.readingFromGameClient.contextMenus |> List.map identifyingInfoFromContextMenu)
                            == (previousReadingFromGameClient.contextMenus |> List.map identifyingInfoFromContextMenu)
                    then
                        Common.DecisionPath.describeBranch "Made no progress in existing cascade"
                            beginCascade

                    else
                        case
                            useContextMenu
                                |> unpackContextMenuTreeToListOfActionsDependingOnReadings
                                {-
                                   2023-01-12 Adapt to behavior of menu from surroundings button:
                                   When opening that menu, the game client opens not only the first level but sometimes also expands the 'stations' entry so that we immediately also have the second level on screen.
                                -}
                                |> List.drop
                                    (min
                                        (List.length cascadeFollowingElements)
                                        (context.contextMenuCascadeLevel - 1)
                                    )
                                |> List.head
                        of
                            Nothing ->
                                beginCascade

                            Just descriptionAndEffectsFromReading ->
                                let
                                    readingFromGameClientForSelectingMenuEntry =
                                        { readingFromGameClient
                                            | contextMenus =
                                                readingFromGameClient.contextMenus
                                                    |> List.reverse
                                                    |> List.take context.contextMenuCascadeLevel
                                                    |> List.reverse
                                        }

                                    ( stepDescription, maybeEffectsToGameClient ) =
                                        descriptionAndEffectsFromReading readingFromGameClientForSelectingMenuEntry
                                in
                                Common.DecisionPath.describeBranch stepDescription
                                    (case maybeEffectsToGameClient of
                                        Nothing ->
                                            beginCascade

                                        Just effectsToGameClient ->
                                            decideActionForCurrentStep effectsToGameClient
                                    )


identifyingInfoFromContextMenu : { a | uiNode : { b | totalDisplayRegion : c } } -> c
identifyingInfoFromContextMenu =
    .uiNode >> .totalDisplayRegion


ensureInfoPanelLocationInfoIsExpanded : ReadingFromGameClient -> Maybe DecisionPathNode
ensureInfoPanelLocationInfoIsExpanded readingFromGameClient =
    case readingFromGameClient.infoPanelContainer |> Maybe.andThen .infoPanelLocationInfo of
        Nothing ->
            Just
                (Common.DecisionPath.describeBranch "I do not see the location info panel. Enable the info panel."
                    (case readingFromGameClient.infoPanelContainer |> Maybe.andThen .icons |> Maybe.andThen .locationInfo of
                        Nothing ->
                            Common.DecisionPath.describeBranch "I do not see the icon for the location info panel." askForHelpToGetUnstuck

                        Just iconLocationInfoPanel ->
                            Common.DecisionPath.describeBranch
                                "Click on the icon to enable the info panel."
                                (iconLocationInfoPanel
                                    |> mouseClickOnUIElement Common.EffectOnWindow.MouseButtonLeft
                                    |> decideActionForCurrentStep
                                )
                    )
                )

        Just infoPanelLocationInfo ->
            if 35 < infoPanelLocationInfo.uiNode.totalDisplayRegion.height then
                Nothing

            else
                Just
                    (Common.DecisionPath.describeBranch "Location info panel seems collapsed."
                        (Common.DecisionPath.describeBranch "Click to expand the info panel."
                            ({ x = infoPanelLocationInfo.uiNode.totalDisplayRegion.x + 8
                             , y = infoPanelLocationInfo.uiNode.totalDisplayRegion.y + 8
                             }
                                |> Common.EffectOnWindow.effectsMouseClickAtLocation
                                    Common.EffectOnWindow.MouseButtonLeft
                                |> decideActionForCurrentStep
                            )
                        )
                    )


branchDependingOnDockedOrInSpace :
    { ifDocked : DecisionPathNode
    , ifSeeShipUI : EveOnline.ParseUserInterface.ShipUI -> Maybe DecisionPathNode
    , ifUndockingComplete : SeeUndockingComplete -> DecisionPathNode
    }
    -> ReadingFromGameClient
    -> DecisionPathNode
branchDependingOnDockedOrInSpace { ifDocked, ifSeeShipUI, ifUndockingComplete } readingFromGameClient =
    case readingFromGameClient.shipUI of
        Nothing ->
            Common.DecisionPath.describeBranch "I see no ship UI, assume we are docked." ifDocked

        Just shipUI ->
            ifSeeShipUI shipUI
                |> Maybe.withDefault
                    (case readingFromGameClient.overviewWindow of
                        Nothing ->
                            Common.DecisionPath.describeBranch
                                "I see no overview window, wait until undocking completed."
                                waitForProgressInGame

                        Just overviewWindow ->
                            Common.DecisionPath.describeBranch "I see ship UI and overview, undocking complete."
                                (ifUndockingComplete
                                    { shipUI = shipUI, overviewWindow = overviewWindow }
                                )
                    )


waitForProgressInGame : DecisionPathNode
waitForProgressInGame =
    Common.DecisionPath.describeBranch "Wait for progress in game"
        (decideActionForCurrentStep [])
        |> updateMillisecondsToNextReadingFromGameModifierPercent (always 100)


askForHelpToGetUnstuck : DecisionPathNode
askForHelpToGetUnstuck =
    Common.DecisionPath.describeBranch "I am stuck here and need help to continue."
        (decideActionForCurrentStep [])
        |> updateMillisecondsToNextReadingFromGameModifierPercent (always 100)


readShipUIModuleButtonTooltipWhereNotYetInMemory :
    { a
        | readingFromGameClient : ReadingFromGameClient
        , memory : { b | shipModules : ShipModulesMemory }
    }
    -> Maybe DecisionPathNode
readShipUIModuleButtonTooltipWhereNotYetInMemory context =
    context.readingFromGameClient.shipUI
        |> Maybe.map .moduleButtons
        |> Maybe.withDefault []
        |> List.filter (getModuleButtonTooltipFromModuleButton context.memory.shipModules >> (==) Nothing)
        |> List.head
        |> Maybe.map
            (\moduleButtonWithoutMemoryOfTooltip ->
                Common.DecisionPath.describeBranch "Read tooltip for module button"
                    (decideActionForCurrentStep
                        (EveOnline.BotFramework.mouseMoveToUIElement moduleButtonWithoutMemoryOfTooltip.uiNode)
                    )
            )


updateMillisecondsToNextReadingFromGameModifierPercent : (Int -> Int) -> DecisionPathNode -> DecisionPathNode
updateMillisecondsToNextReadingFromGameModifierPercent update decisionPath =
    updateDecisionPathEndContinueSession
        (\continueSession ->
            { continueSession
                | millisecondsToNextReadingFromGameModifierPercent =
                    update continueSession.millisecondsToNextReadingFromGameModifierPercent
            }
        )
        decisionPath


setMillisecondsToNextReadingFromGameBase : Int -> DecisionPathNode -> DecisionPathNode
setMillisecondsToNextReadingFromGameBase millisecondsToNextReadingFromGameBase decisionPath =
    updateDecisionPathEndContinueSession
        (\continueSession ->
            { continueSession | millisecondsToNextReadingFromGameBase = Just millisecondsToNextReadingFromGameBase }
        )
        decisionPath


updateDecisionPathEndContinueSession : (ContinueSessionStructure -> ContinueSessionStructure) -> DecisionPathNode -> DecisionPathNode
updateDecisionPathEndContinueSession updateContinueSession decisionPath =
    Common.DecisionPath.continueDecisionPath
        (\pathEnd ->
            Common.DecisionPath.endDecisionPath
                (case pathEnd of
                    ContinueSession continueSession ->
                        ContinueSession (updateContinueSession continueSession)

                    FinishSession ->
                        pathEnd
                )
        )
        decisionPath


decideActionForCurrentStep : List Common.EffectOnWindow.EffectOnWindowStructure -> DecisionPathNode
decideActionForCurrentStep effects =
    Common.DecisionPath.endDecisionPath
        (ContinueSession
            { effectsOnGameClient = effects
            , millisecondsToNextReadingFromGameBase = Nothing
            , millisecondsToNextReadingFromGameModifierPercent = 0
            }
        )