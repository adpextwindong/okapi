{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Applicative ((<|>))
import Control.Applicative.Combinators
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Data.Aeson (ToJSON, toJSON)
import Data.ByteString.Lazy (fromStrict)
import Data.Function ((&))
import Data.Maybe (listToMaybe)
import Data.Text
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import GHC.Generics (Generic, Par1)
import Okapi
import Web.FormUrlEncoded (FromForm)
import Web.HttpApiData (ToHttpApiData)
import Web.Internal.HttpApiData

{-
We're going to build a Todo API with the following endpoints:

GET /
Health check. Returns 200 response with "OK" as the body.

GET /todos
Returns all todos as JSON. Has optional query param "status" to filter todos with that status.

GET /todos/:uid
Returns the todo with the matching :uid as JSON.

POST /todos
Accepts a todo/todos encoded as JSON to store on the server.

PATCH /todos/:uid
Accepts todo information as JSON. For updating a todo with the :uid.

DELETE /todos/:uid
Deletes the todo with the matching :uid from the server.
-}

-- TYPES --

data Todo = Todo
  { todoID :: Int,
    todoName :: Text,
    todoStatus :: TodoStatus
  }
  deriving (Eq, Ord, Generic, ToJSON, Show)

instance FromRow Todo where
  fromRow = Todo <$> field <*> field <*> field

data TodoForm = TodoForm
  { todoFormName :: Text,
    todoFormStatus :: TodoStatus
  }
  deriving (Eq, Ord, Generic, FromForm, Show)

instance ToRow TodoForm where
  toRow (TodoForm name status) = toRow (name, status)

data TodoStatus
  = Incomplete
  | Archived
  | Complete
  deriving (Eq, Ord, Show)

instance ToJSON TodoStatus where
  toJSON Incomplete = "incomplete"
  toJSON Archived = "archived"
  toJSON Complete = "complete"

instance FromHttpApiData TodoStatus where
  parseQueryParam "incomplete" = Right Incomplete
  parseQueryParam "archived" = Right Archived
  parseQueryParam "complete" = Right Complete
  parseQueryParam _ = Left "Incorrect format for TodoStatus value"

instance ToField TodoStatus where
  toField status =
    case status of
      Incomplete -> SQLText "incomplete"
      Archived -> SQLText "archived"
      Complete -> SQLText "complete"

instance FromField TodoStatus where
  fromField field = do
    case fieldData field of
      SQLText "incomplete" -> pure Incomplete
      SQLText "archived" -> pure Archived
      SQLText "complete" -> pure Complete
      _ -> returnError ConversionFailed field "Couldn't methodGET TodoStatus value from field"

type Okapi = OkapiT IO

-- MAIN --

main :: IO ()
main = do
  conn <- open "todo.db"
  execute_ conn "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY, name TEXT, status TEXT)"
  run id (todoAPI conn)
  close conn

-- SERVER FUNCTIONS

respond :: Response -> Okapi Response
respond response = do
  methodEnd
  pathEnd
  return response

pattern HealthCheck :: Path
pattern HealthCheck = [""]

pattern GetAllTodos :: Path
pattern GetAllTodos = ["todos"]

pattern GetTodo :: Int -> Path
pattern GetTodo todoID = ["todos", Seg todoID]

pattern PutTodo :: Int -> Path
pattern PutTodo todoID = ["todos", Seg todoID]

pattern CreateTodo :: Path
pattern CreateTodo = ["todos"]

pattern ForgetTodo :: Int -> Path
pattern ForgetTodo todoID = ["todos", Seg todoID]

todoAPI :: Connection -> Okapi Response
todoAPI conn =
  getRoutes conn
    <|> postRoutes conn
    <|> putRoutes conn
    <|> deleteRoutes conn

getRoutes :: Connection -> Okapi Response
getRoutes conn = do
  methodGET
  route $ \case
    HealthCheck -> respond ok
    GetTodo todoID -> do
      maybeTodo <- lift $ selectTodo conn todoID
      case maybeTodo of
        Nothing -> throw internalServerError
        Just todo -> ok & setJSON todo & respond
    GetAllTodos -> do
      maybeStatus <- optional $ queryParam @TodoStatus "status"
      todos <- lift $ selectAllTodos conn maybeStatus
      ok & setJSON todos & respond
    _ -> next

postRoutes :: Connection -> Okapi Response
postRoutes conn = do
  methodPOST
  route $ \case
    CreateTodo -> do
      todoForm <- bodyForm
      lift $ insertTodoForm conn todoForm
      respond ok
    _ -> next

putRoutes :: Connection -> Okapi Response
putRoutes conn = do
  methodPUT
  route $ \case
    PutTodo todoID -> do
      todoForm <- bodyForm @TodoForm
      lift $ updateTodo conn todoID todoForm
      respond ok
    _ -> next

deleteRoutes :: Connection -> Okapi Response
deleteRoutes conn = do
  methodDELETE
  route $ \case
    ForgetTodo todoID -> do
      lift $ deleteTodo conn todoID
      respond ok
    _ -> next

-- DATABASE FUNCTIONS

insertTodoForm :: Connection -> TodoForm -> IO ()
insertTodoForm conn = execute conn "INSERT INTO todos (name, status) VALUES (?, ?)"

selectTodo :: Connection -> Int -> IO (Maybe Todo)
selectTodo conn todoID = listToMaybe <$> Database.SQLite.Simple.query conn "SELECT * FROM todos WHERE id = ?" (Only todoID)

selectAllTodos :: Connection -> Maybe TodoStatus -> IO [Todo]
selectAllTodos conn maybeStatus = case maybeStatus of
  Nothing -> query_ conn "SELECT * FROM todos"
  Just status -> Database.SQLite.Simple.query conn "SELECT * FROM todos WHERE status = ?" (Only status)

updateTodo :: Connection -> Int -> TodoForm -> IO ()
updateTodo conn todoID TodoForm {..} =
  executeNamed
    conn
    "UPDATE todos SET name = :name, status = :status WHERE id = :id"
    [":id" := todoID, ":name" := todoFormName, ":status" := todoFormStatus]

deleteTodo :: Connection -> Int -> IO ()
deleteTodo conn todoID = execute conn "DELETE FROM todos WHERE id = ?" (Only todoID)
