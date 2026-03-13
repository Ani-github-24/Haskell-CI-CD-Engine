-- |
-- Module      : UI
-- Description : Lucid HTML templates with TailwindCSS (CDN) and HTMX for the CI/CD dashboard.
module UI
    ( dashboardPage
    , pipelineDetailPage
    , metricsText
    ) where

import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Time          (UTCTime, formatTime,
                                     defaultTimeLocale, diffUTCTime)
import           Database.Persist   (Entity (..), Key)
import           Database.Persist.Sql (fromSqlKey)
import           Lucid
import           Lucid.Base        (makeAttribute)

import           Database           (Pipeline (..), Job (..))

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- | Base HTML page layout with TailwindCSS and HTMX loaded from CDN.
basePage :: Monad m => Text -> HtmlT m () -> HtmlT m ()
basePage title' content = doctypehtml_ $ do
    head_ $ do
        meta_ [charset_ "utf-8"]
        meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1.0"]
        title_ (toHtml title')
        -- TailwindCSS via CDN
        script_ [src_ "https://cdn.tailwindcss.com"] ("" :: Text)
        -- HTMX via CDN
        script_ [src_ "https://unpkg.com/htmx.org@1.9.10"] ("" :: Text)
        -- HTMX WebSocket extension
        script_ [src_ "https://unpkg.com/htmx.org@1.9.10/dist/ext/ws.js"] ("" :: Text)
        -- Custom styles
        style_ customCSS
    body_ [class_ "bg-gray-950 text-gray-100 min-h-screen font-sans"] $ do
        navbar
        div_ [class_ "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8"] content

-- | Top navigation bar.
navbar :: Monad m => HtmlT m ()
navbar =
    nav_ [class_ "bg-gray-900/80 backdrop-blur-xl border-b border-gray-800 sticky top-0 z-50"] $
        div_ [class_ "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8"] $
            div_ [class_ "flex items-center justify-between h-16"] $ do
                -- Logo
                a_ [href_ "/", class_ "flex items-center space-x-3 group"] $ do
                    div_ [class_ "w-8 h-8 bg-gradient-to-br from-indigo-500 to-purple-600 rounded-lg flex items-center justify-center shadow-lg shadow-indigo-500/25 group-hover:shadow-indigo-500/40 transition-shadow"] $
                        span_ [class_ "text-white font-bold text-sm"] "CI"
                    span_ [class_ "text-xl font-bold bg-gradient-to-r from-indigo-400 to-purple-400 bg-clip-text text-transparent"] "CI/CD Engine"
                -- Nav links
                div_ [class_ "flex items-center space-x-6"] $ do
                    a_ [href_ "/", class_ "text-gray-400 hover:text-white transition-colors text-sm font-medium"] "Dashboard"
                    a_ [href_ "/metrics", class_ "text-gray-400 hover:text-white transition-colors text-sm font-medium"] "Metrics"

-- | Extra CSS for animations, glass effects, and timeline.
customCSS :: Text
customCSS = T.unlines
    [ "@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');"
    , "body { font-family: 'Inter', sans-serif; }"
    , ".glass { background: rgba(255,255,255,0.03); backdrop-filter: blur(12px); border: 1px solid rgba(255,255,255,0.06); }"
    , ".status-pulse { animation: pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; }"
    , "@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: .5; } }"
    , ".log-container { scrollbar-width: thin; scrollbar-color: #4b5563 transparent; }"
    , ".log-container::-webkit-scrollbar { width: 6px; }"
    , ".log-container::-webkit-scrollbar-thumb { background: #4b5563; border-radius: 3px; }"
    , ".fade-in { animation: fadeIn 0.3s ease-in-out; }"
    , "@keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }"
    -- Timeline animations
    , ".tl-ring { animation: ringPulse 1.5s ease-in-out infinite; }"
    , "@keyframes ringPulse { 0% { box-shadow: 0 0 0 0 rgba(96,165,250,0.5); } 70% { box-shadow: 0 0 0 8px rgba(96,165,250,0); } 100% { box-shadow: 0 0 0 0 rgba(96,165,250,0); } }"
    , ".tl-connector { transition: background-color 0.4s ease; }"
    , ".tl-step { animation: stepIn 0.35s ease-out both; }"
    , "@keyframes stepIn { from { opacity: 0; transform: translateX(-12px); } to { opacity: 1; transform: translateX(0); } }"
    , ".tl-error-flash { animation: errorFlash 2s ease-in-out infinite; }"
    , "@keyframes errorFlash { 0%, 100% { border-color: rgba(248,113,113,0.3); } 50% { border-color: rgba(248,113,113,0.7); } }"
    ]

-- ---------------------------------------------------------------------------
-- Dashboard Page (GET /)
-- ---------------------------------------------------------------------------

-- | Render the main dashboard showing recent pipelines.
dashboardPage :: [Entity Pipeline] -> Html ()
dashboardPage pipelines = basePage "Dashboard — CI/CD Engine" $ do
    -- Header
    div_ [class_ "mb-8 fade-in"] $ do
        h1_ [class_ "text-3xl font-bold text-white mb-2"] "Pipeline Dashboard"
        p_ [class_ "text-gray-400 text-sm"] "Recent pipeline executions and their status."

    -- Stats strip
    div_ [class_ "grid grid-cols-1 md:grid-cols-4 gap-4 mb-8 fade-in"] $ do
        statCard "Total Runs" (showT $ length pipelines) "from-blue-500 to-cyan-500"
        statCard "Successful" (countByStatus "Success" pipelines) "from-emerald-500 to-green-500"
        statCard "Failed"     (countByStatus "Failed" pipelines) "from-red-500 to-rose-500"
        statCard "Pending"    (countByStatus "Pending" pipelines) "from-amber-500 to-yellow-500"

    -- Pipeline table
    div_ [class_ "glass rounded-2xl overflow-hidden fade-in"] $ do
        div_ [class_ "px-6 py-4 border-b border-gray-800"] $
            h2_ [class_ "text-lg font-semibold text-white"] "Recent Pipelines"
        if null pipelines
            then div_ [class_ "p-12 text-center"] $
                     p_ [class_ "text-gray-600 text-sm"] "No pipelines yet. POST to /webhook to trigger one."
            else table_ [class_ "w-full"] $ do
                thead_ $
                    tr_ [class_ "text-left text-xs font-medium text-gray-500 uppercase tracking-wider"] $ do
                        th_ [class_ "px-6 py-3"] "Pipeline"
                        th_ [class_ "px-6 py-3"] "Commit"
                        th_ [class_ "px-6 py-3"] "Status"
                        th_ [class_ "px-6 py-3"] "Created"
                        th_ [class_ "px-6 py-3"] ""
                tbody_ [class_ "divide-y divide-gray-800/50"] $
                    mapM_ pipelineRow pipelines

-- | Single row in the pipeline table.
pipelineRow :: Entity Pipeline -> Html ()
pipelineRow (Entity pk pipeline) = do
    let pid = showT (fromSqlKey pk)
    tr_ [class_ "hover:bg-white/[0.02] transition-colors group"] $ do
        td_ [class_ "px-6 py-4"] $
            span_ [class_ "font-medium text-white"] (toHtml $ pipelineName pipeline)
        td_ [class_ "px-6 py-4"] $
            code_ [class_ "text-xs bg-gray-800 text-indigo-400 px-2 py-1 rounded-md font-mono"]
                (toHtml . T.take 7 $ pipelineCommitHash pipeline)
        td_ [class_ "px-6 py-4"] $
            statusBadge (pipelineStatus pipeline)
        td_ [class_ "px-6 py-4 text-sm text-gray-500"] $
            toHtml (formatUTC $ pipelineCreatedAt pipeline)
        td_ [class_ "px-6 py-4 text-right"] $
            a_ [ href_ ("/pipeline/" <> pid)
               , class_ "text-indigo-400 hover:text-indigo-300 text-sm font-medium opacity-0 group-hover:opacity-100 transition-opacity"
               ] "View →"

-- | Render a colored status badge.
statusBadge :: Monad m => Text -> HtmlT m ()
statusBadge status' =
    let (bgColor, dotColor, textColor) = statusColors status'
        pulseClass = if status' == "Running" then " status-pulse" else ""
    in span_ [class_ ("inline-flex items-center space-x-1.5 px-2.5 py-1 rounded-full text-xs font-medium " <> bgColor <> " " <> textColor)] $ do
        span_ [class_ ("w-1.5 h-1.5 rounded-full " <> dotColor <> pulseClass)] ""
        span_ [] (toHtml status')

statusColors :: Text -> (Text, Text, Text)
statusColors "Success" = ("bg-emerald-500/10", "bg-emerald-400", "text-emerald-400")
statusColors "Failed"  = ("bg-red-500/10",     "bg-red-400",     "text-red-400")
statusColors "Running" = ("bg-blue-500/10",    "bg-blue-400",    "text-blue-400")
statusColors "Pending" = ("bg-amber-500/10",   "bg-amber-400",   "text-amber-400")
statusColors "Skipped" = ("bg-gray-500/10",    "bg-gray-400",    "text-gray-400")
statusColors _         = ("bg-gray-500/10",    "bg-gray-400",    "text-gray-400")

-- | A small stat card for the dashboard header.
statCard :: Monad m => Text -> Text -> Text -> HtmlT m ()
statCard label' value' gradient =
    div_ [class_ "glass rounded-xl p-5 hover:border-gray-700 transition-colors"] $ do
        p_ [class_ "text-xs font-medium text-gray-500 uppercase tracking-wider mb-1"] (toHtml label')
        p_ [class_ ("text-2xl font-bold bg-gradient-to-r " <> gradient <> " bg-clip-text text-transparent")]
            (toHtml value')

countByStatus :: Text -> [Entity Pipeline] -> Text
countByStatus s = showT . length . filter (\(Entity _ p) -> pipelineStatus p == s)

-- ---------------------------------------------------------------------------
-- Pipeline Detail Page (GET /pipeline/:id)
-- ---------------------------------------------------------------------------

-- | Render the detail view for a single pipeline with job cards and live log panel.
pipelineDetailPage :: Entity Pipeline -> [Entity Job] -> Text -> Html ()
pipelineDetailPage (Entity _pk pipeline) jobs wsPath = basePage (pipelineName pipeline <> " — CI/CD Engine") $ do
    -- Breadcrumb
    div_ [class_ "mb-6 fade-in"] $
        div_ [class_ "flex items-center space-x-2 text-sm"] $ do
            a_ [href_ "/", class_ "text-gray-500 hover:text-gray-300 transition-colors"] "Dashboard"
            span_ [class_ "text-gray-700"] "/"
            span_ [class_ "text-white font-medium"] (toHtml $ pipelineName pipeline)

    -- Pipeline header
    div_ [class_ "glass rounded-2xl p-6 mb-6 fade-in"] $
        div_ [class_ "flex items-center justify-between"] $ do
            div_ $ do
                h1_ [class_ "text-2xl font-bold text-white mb-1"] (toHtml $ pipelineName pipeline)
                div_ [class_ "flex items-center space-x-3 text-sm text-gray-400"] $ do
                    span_ [] $ do
                        "Commit: "
                        code_ [class_ "text-indigo-400 bg-gray-800 px-1.5 py-0.5 rounded font-mono text-xs"]
                            (toHtml $ pipelineCommitHash pipeline)
                    span_ [class_ "text-gray-700"] "\x2022"
                    span_ [] (toHtml . formatUTC $ pipelineCreatedAt pipeline)
            statusBadge (pipelineStatus pipeline)

    -- Execution Timeline
    div_ [class_ "mb-8 fade-in"] $ do
        h2_ [class_ "text-lg font-semibold text-white mb-5"] "Execution Timeline"
        if null jobs
            then div_ [class_ "glass rounded-2xl p-8 text-center"] $
                     p_ [class_ "text-gray-600 text-sm"] "No execution steps recorded yet."
            else pipelineTimeline jobs

    -- Job DAG cards (grid)
    div_ [class_ "mb-6 fade-in"] $ do
        h2_ [class_ "text-lg font-semibold text-white mb-4"] "Jobs"
        if null jobs
            then p_ [class_ "text-gray-600 text-sm"] "No jobs recorded."
            else div_ [class_ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"] $
                     mapM_ jobCard jobs

    -- Live log stream panel (HTMX WebSocket)
    div_ [class_ "fade-in"] $ do
        h2_ [class_ "text-lg font-semibold text-white mb-4"] "Live Logs"
        div_ [ class_ "glass rounded-2xl overflow-hidden"
             , makeAttribute "hx-ext" "ws"
             , makeAttribute "ws-connect" wsPath
             ] $
            div_ [ id_ "log-stream"
                 , class_ "log-container p-4 h-96 overflow-y-auto font-mono text-xs text-gray-400 space-y-0.5"
                 ] $
                p_ [class_ "text-gray-600 italic"] "Waiting for log stream\x2026"

-- | Render a single job card.
jobCard :: Entity Job -> Html ()
jobCard (Entity _ job) =
    div_ [class_ "glass rounded-xl p-4 hover:border-gray-700 transition-colors"] $ do
        div_ [class_ "flex items-center justify-between mb-3"] $ do
            span_ [class_ "font-medium text-white text-sm"] (toHtml $ jobName job)
            statusBadge (jobStatus job)
        div_ [class_ "space-y-1.5 text-xs text-gray-500"] $ do
            div_ [class_ "flex items-center space-x-2"] $ do
                span_ [class_ "text-gray-600"] "Image:"
                code_ [class_ "text-purple-400 bg-gray-800/50 px-1.5 py-0.5 rounded font-mono"]
                    (toHtml $ jobDockerImage job)
            case jobStartedAt job of
                Just t  -> div_ [] $ do
                    span_ [class_ "text-gray-600"] "Started: "
                    span_ [] (toHtml $ formatUTC t)
                Nothing -> mempty
            case jobFinishedAt job of
                Just t  -> div_ [] $ do
                    span_ [class_ "text-gray-600"] "Finished: "
                    span_ [] (toHtml $ formatUTC t)
                Nothing -> mempty

-- ---------------------------------------------------------------------------
-- Execution Timeline
-- ---------------------------------------------------------------------------

-- | Render the full vertical execution timeline.
pipelineTimeline :: [Entity Job] -> Html ()
pipelineTimeline jobs =
    div_ [class_ "glass rounded-2xl p-6"] $
        div_ [class_ "relative"] $
            mapM_ (\(idx, ej) -> timelineStep ej (idx == length jobs - 1) idx) (zip [0..] jobs)

-- | A single step in the vertical timeline.
timelineStep :: Entity Job -> Bool -> Int -> Html ()
timelineStep (Entity _ job) isLast idx = do
    let status'     = jobStatus job
        isFailed    = status' == "Failed"
        isRunning   = status' == "Running"
        delayStyle  = "animation-delay: " <> showT (idx * 80) <> "ms;"
    -- Step container with stagger animation
    div_ [class_ "tl-step flex gap-4", style_ delayStyle] $ do
        -- Left: icon column with connector line
        div_ [class_ "flex flex-col items-center"] $ do
            -- Status icon
            timelineIcon status'
            -- Connector line (skip for last step)
            unless isLast $
                div_ [class_ ("tl-connector w-0.5 flex-1 min-h-[2rem] " <> connectorColor status')] ""

        -- Right: content card
        div_ [class_ ("flex-1 pb-6 " <> if isLast then "" else "")] $ do
            div_ [class_ (stepCardClass isFailed)] $ do
                -- Header row: name + badge
                div_ [class_ "flex items-center justify-between mb-2"] $ do
                    div_ [class_ "flex items-center space-x-2"] $ do
                        span_ [class_ "font-semibold text-white text-sm"] (toHtml $ jobName job)
                        span_ [class_ "text-gray-600 text-xs"] (toHtml $ "Step " <> showT (idx + 1))
                    statusBadge status'

                -- Details row
                div_ [class_ "flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-gray-500 mb-2"] $ do
                    -- Docker image
                    div_ [class_ "flex items-center space-x-1"] $ do
                        span_ [class_ "text-gray-600"] "\x1f4e6"
                        code_ [class_ "text-purple-400 bg-gray-800/50 px-1.5 py-0.5 rounded font-mono"]
                            (toHtml $ jobDockerImage job)
                    -- Timestamps
                    case jobStartedAt job of
                        Just t -> div_ [class_ "flex items-center space-x-1"] $ do
                            span_ [class_ "text-gray-600"] "Started:"
                            span_ [] (toHtml $ formatUTC t)
                        Nothing -> mempty
                    case jobFinishedAt job of
                        Just t -> div_ [class_ "flex items-center space-x-1"] $ do
                            span_ [class_ "text-gray-600"] "Finished:"
                            span_ [] (toHtml $ formatUTC t)
                        Nothing -> mempty
                    -- Duration (if both timestamps available)
                    case (jobStartedAt job, jobFinishedAt job) of
                        (Just s, Just e) ->
                            div_ [class_ "flex items-center space-x-1"] $ do
                                span_ [class_ "text-gray-600"] "Duration:"
                                span_ [class_ "text-indigo-400 font-medium"] (toHtml $ formatDuration s e)
                        _ -> mempty

                -- Error banner for failed jobs
                when isFailed $
                    div_ [class_ "mt-3 bg-red-500/10 border border-red-500/30 rounded-lg px-3 py-2 tl-error-flash"] $
                        div_ [class_ "flex items-center space-x-2"] $ do
                            span_ [class_ "text-red-400 font-bold text-xs"] "\x2717 ERROR"
                            span_ [class_ "text-red-300 text-xs"]
                                "This step failed. Check the logs below for details."

                -- Running indicator
                when isRunning $
                    div_ [class_ "mt-3 bg-blue-500/10 border border-blue-500/20 rounded-lg px-3 py-2"] $
                        div_ [class_ "flex items-center space-x-2"] $ do
                            div_ [class_ "w-2 h-2 bg-blue-400 rounded-full status-pulse"] ""
                            span_ [class_ "text-blue-300 text-xs font-medium"]
                                "Currently executing..."

                -- Skipped indicator
                when (status' == "Skipped") $
                    div_ [class_ "mt-3 bg-gray-500/10 border border-gray-500/20 rounded-lg px-3 py-2"] $
                        span_ [class_ "text-gray-500 text-xs"]
                            "Skipped due to upstream failure."

-- | Render the timeline step icon based on status.
timelineIcon :: Monad m => Text -> HtmlT m ()
timelineIcon "Success" =
    div_ [class_ "w-8 h-8 rounded-full bg-emerald-500/20 border-2 border-emerald-500 flex items-center justify-center flex-shrink-0"] $
        span_ [class_ "text-emerald-400 text-xs font-bold"] "\x2713"
timelineIcon "Failed" =
    div_ [class_ "w-8 h-8 rounded-full bg-red-500/20 border-2 border-red-500 flex items-center justify-center flex-shrink-0"] $
        span_ [class_ "text-red-400 text-xs font-bold"] "\x2717"
timelineIcon "Running" =
    div_ [class_ "w-8 h-8 rounded-full bg-blue-500/20 border-2 border-blue-400 flex items-center justify-center flex-shrink-0 tl-ring"] $
        div_ [class_ "w-2.5 h-2.5 bg-blue-400 rounded-full status-pulse"] ""
timelineIcon "Skipped" =
    div_ [class_ "w-8 h-8 rounded-full bg-gray-700/50 border-2 border-gray-600 flex items-center justify-center flex-shrink-0"] $
        span_ [class_ "text-gray-500 text-xs"] "-"
timelineIcon _ = -- Pending
    div_ [class_ "w-8 h-8 rounded-full bg-gray-800 border-2 border-gray-600 border-dashed flex items-center justify-center flex-shrink-0"] $
        div_ [class_ "w-2 h-2 bg-gray-600 rounded-full"] ""

-- | Connector line color based on the status of the step above it.
connectorColor :: Text -> Text
connectorColor "Success" = "bg-emerald-500/40"
connectorColor "Failed"  = "bg-red-500/40"
connectorColor "Running" = "bg-blue-500/40"
connectorColor _         = "bg-gray-700"

-- | CSS class for the step content card, with error flash for failed steps.
stepCardClass :: Bool -> Text
stepCardClass True  = "glass rounded-xl p-4 border border-red-500/30 tl-error-flash"
stepCardClass False = "glass rounded-xl p-4"

-- | Format duration between two timestamps as human-readable text.
formatDuration :: UTCTime -> UTCTime -> Text
formatDuration start end =
    let diffSecs = floor (realToFrac (diffUTCTime end start) :: Double) :: Int
        mins     = diffSecs `div` 60
        secs     = diffSecs `mod` 60
    in  if mins > 0
        then showT mins <> "m " <> showT secs <> "s"
        else showT secs <> "s"

-- | Helper: 'when' for Lucid monadic context.
when :: Monad m => Bool -> HtmlT m () -> HtmlT m ()
when True  m = m
when False _ = mempty

-- | Helper: 'unless' for Lucid monadic context.
unless :: Monad m => Bool -> HtmlT m () -> HtmlT m ()
unless b = when (not b)

-- ---------------------------------------------------------------------------
-- Metrics (Prometheus text format)
-- ---------------------------------------------------------------------------

-- | Render Prometheus-style metrics as plain text.
metricsText :: Int -> Int -> Text
metricsText pending active = T.unlines
    [ "# HELP cicd_pending_jobs Number of jobs waiting in the queue."
    , "# TYPE cicd_pending_jobs gauge"
    , "cicd_pending_jobs " <> showT pending
    , ""
    , "# HELP cicd_active_workers Number of currently active worker threads."
    , "# TYPE cicd_active_workers gauge"
    , "cicd_active_workers " <> showT active
    ]

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

formatUTC :: UTCTime -> Text
formatUTC = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

showT :: Show a => a -> Text
showT = T.pack . show

