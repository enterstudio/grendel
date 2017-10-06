{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Data.Aeson hiding (json)
import Data.Aeson.QQ
import Data.Monoid ((<>))
import Web.Scotty
import Data.Maybe
import Data.List
import Data.Grendy.BigQuery
import Data.Grendy.GraphQL
import System.Environment (getEnv)
import Data.String.Conversions (cs)
import Data.Time.Clock
import Data.Time.Calendar
import Text.Printf (printf)

-- | This function takes a list of (GitHub) repos and a list of (bigquery)
-- repo name / today stars pairs and applies the todays stars data from
-- big query to the github repos. In other words, add the number of todays
-- stars to each repo, since this data is not provided by GitHub.
applyTodayStars  :: [Repo] -> [TodayStar] -> [Repo]
applyTodayStars repo lang = catMaybes $ applyTodayStars' repo <$> lang
  where
    applyTodayStars' repo lang =
      case find (\r -> name r == getName lang) repo of
             Just r' -> Just r' { todayStars = Just (getStars lang) }
             Nothing -> Nothing

ghQuery :: String -> Value
ghQuery repos = [aesonQQ|
{
    "query": "query ($repos: String!) {
        search(first: 100, type: REPOSITORY, query: $repos) {
            edges {
                node {
                    ... on Repository {
                        nameWithOwner
                        createdAt
                        description
                        license
                        primaryLanguage {
                            name
                        }
                        stargazers {
                            totalCount
                        }
                        owner {
                            avatarUrl
                        }
                    }
                }
            }
        }
    }",

    "variables": {
        "repos": #{repos}
    },

    "operationName": null
}
|]

bigQuerySQL :: String -> String
bigQuerySQL time =
     "SELECT events.repo.name AS repo,\
    \ COUNT(DISTINCT events.actor.id) AS stars\
    \ FROM ( SELECT * FROM [githubarchive:day." <> time <> "]) AS events\
    \ WHERE events.type = 'WatchEvent'\
    \ GROUP BY 1 ORDER BY 2 DESC LIMIT 1000"

starsToString :: [TodayStar] -> String
starsToString = ("repo:" <>) . intercalate " repo:" . take 100 . fmap getName

starsToStrings :: [[TodayStar]] -> [String]
starsToStrings = fmap starsToString

checkAPIError :: Either [Char] t -> t
checkAPIError (Right b) = b
checkAPIError (Left err) = error err

fetchRepo :: String -> IO [Repo]
fetchRepo query = do
  let graphQL = graphQuery . ghQuery $ query
  repos <- checkAPIError <$> graphQL
  pure repos

fetchRepos :: [TodayStar] -> IO [Repo]
fetchRepos stars = do
  repos <- fetchRepo $ starsToString stars
  case (length stars < 100) of
        True -> return repos
        otherwise -> pure repos <> fetchRepos (drop 100 stars)

main :: IO ()
main = do
  UTCTime day time <- getCurrentTime
  let yesterday = UTCTime (addDays (-1) day) time
  let (y, m, d) = toGregorian $ utctDay yesterday
  let format x = (printf "%02s"(show x))
  let sqldate = (show y) <> (format m) <> (format d)
  port <- read <$> getEnv "PORT"
  stars <- checkAPIError <$> bigQuery (bigQuerySQL sqldate)
  repos <- fetchRepos (take 500 stars)
  let static = applyTodayStars (repos) stars
  scotty port $ do
    get "" $ do
      setHeader "Access-Control-Allow-Origin" "https://madnight.github.io"
      json $ static
