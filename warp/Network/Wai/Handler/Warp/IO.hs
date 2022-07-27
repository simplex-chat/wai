{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Network.Wai.Handler.Warp.IO where

import Control.Exception (mask_)
import Data.ByteString.Builder (Builder)
import Data.ByteString.Builder.Extra (Next (Chunk, Done, More), runBuilder)
import Data.IORef (IORef, readIORef, writeIORef)
import Network.Wai.Handler.Warp.Buffer
import Network.Wai.Handler.Warp.Imports
import Network.Wai.Handler.Warp.Types

toBufIOWith :: IORef WriteBuffer -> (ByteString -> IO ()) -> Builder -> IO ()
toBufIOWith writeBufferRef io builder = do
  writeBuffer <- readIORef writeBufferRef
  loop writeBuffer firstWriter
  where
    firstWriter = runBuilder builder
    loop writeBuffer writer = do
      let buf = bufBytes writeBuffer
          size = bufSize writeBuffer
      (len, signal) <- writer buf size
      bufferIO buf len io
      case signal of
        Done -> return ()
        More minSize next
          | size < minSize -> do
              -- The current WriteBuffer is too small to fit the next
              -- batch of bytes from the Builder so we free it and
              -- create a new bigger one. Freeing the current buffer,
              -- creating a new one and writing it to the IORef need
              -- to be performed atomically to prevent both double
              -- frees and missed frees. So we mask async exceptions:
              writeBuffer' <- mask_ $ do
                bufFree writeBuffer
                writeBuffer' <- createWriteBuffer minSize
                writeIORef writeBufferRef writeBuffer'
                return writeBuffer'
              loop writeBuffer' next
          | otherwise -> loop writeBuffer next
        Chunk bs next -> do
          io bs
          loop writeBuffer next
