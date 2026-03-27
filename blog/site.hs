{-# LANGUAGE OverloadedStrings #-}

import           Hakyll

main :: IO ()
main = hakyll $ do

    -- Static assets
    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    -- Individual posts
    match "posts/*" $ do
        route $ setExtension "html"
        compile $ pandocCompiler
            >>= saveSnapshot "content"
            >>= loadAndApplyTemplate "templates/post.html"    postCtx
            >>= loadAndApplyTemplate "templates/default.html" postCtx
            >>= relativizeUrls

    -- Index page (uses index.html with post-list partial)
    match "index.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let indexCtx =
                    listField "posts" postCtx (return posts) <>
                    defaultContext
            getResourceBody
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/default.html" indexCtx
                >>= relativizeUrls

    -- Archive page
    match "templates/archive.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/*"
            let archiveCtx =
                    listField "posts" postCtx (return posts) <>
                    defaultContext
            getResourceBody
                >>= applyAsTemplate archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" archiveCtx
                >>= relativizeUrls

    -- Atom feed
    create ["atom.xml"] $ do
        route idRoute
        compile $ do
            posts <- fmap (take 20) . recentFirst
                 =<< loadAllSnapshots "posts/*" "content"
            renderAtom feedConfig feedCtx posts

    -- Templates
    match "templates/*" $ compile templateBodyCompiler

postCtx :: Context String
postCtx =
    dateField "date" "%B %e, %Y" <>
    defaultContext

feedCtx :: Context String
feedCtx =
    bodyField "description" <>
    postCtx

feedConfig :: FeedConfiguration
feedConfig = FeedConfiguration
    { feedTitle       = "MetaSonic / tinysynth blog"
    , feedDescription = "Design notes on a typed compiler pipeline for realtime audio"
    , feedAuthorName  = "Bernardo Barros"
    , feedAuthorEmail = ""
    , feedRoot        = "https://smoge.github.io/metasonic-bridge"
    }
