
module Data.Repa.Flow.Generic.IO
        ( -- * Sourcing Bytes
          fileSourcesBytes,     hSourcesBytes

          -- * Sourcing Records
        , fileSourcesRecords,   hSourcesRecords

          -- * Sinking Bytes
        , fileSinksBytes,       hSinksBytes)
where
import Data.Repa.Flow.Generic.Base
import Data.Repa.IO.Array
import System.IO
import Data.Word
import Data.Repa.Array.Foreign          as R
import Data.Repa.Array                  as R
import Prelude                          as P


-- Source Bytes -----------------------------------------------------------------------------------
-- | Read data from some files, using the given chunk length.
--
--   * Data is read into foreign memory without copying it through the GHC heap.
--   * All chunks have the same size, except possibly the last one.
--
--   TODO: close file when finished.
--
fileSourcesBytes 
        :: [FilePath] -> Int 
        -> IO (Sources Int IO (Vector F Word8))

fileSourcesBytes filePaths len
 = do   hs      <- mapM (flip openBinaryFile ReadMode) filePaths
        hSourcesBytes hs len 
{-# NOINLINE fileSourcesBytes #-}
--  NOINLINE because the chunks should be big enough to not require fusion,
--           and we don't want to release the code for 'openBinaryFile'.


-- | Like `fileSourceBytes`, but taking existing file handles.
hSourcesBytes 
        :: [Handle] -> Int 
        -> IO (Sources Int IO (Vector F Word8))

hSourcesBytes hs len
 = return $ Sources (P.length hs) pull_hSource
 where
        pull_hSource (IIx i _) eat eject
         = let h  = hs !! i
           in do eof <- hIsEOF h
                 if eof 
                  then  eject
                  else do  
                        !chunk  <- hGetArray h len
                        eat chunk
        {-# INLINE pull_hSource #-}
{-# INLINE [2] hSourcesBytes #-}


-- Source Records ---------------------------------------------------------------------------------
-- | Read complete records of data from a file, using the given chunk length
--
--   The records are separated by a special terminating character, which the 
--   given predicate detects. After reading a chunk of data we seek to just after the
--   last complete record that was read, so we can continue to read more complete
--   records next time.
--
--   If we cannot find an end-of-record terminator in the chunk then apply the given
--   failure action. The records can be no longer than the chunk length. This fact
--   guards against the case where a large input file is malformed and contains no 
--   end-of-record terminators, as we won't try to read the whole file into memory.
--
--   * Data is read into foreign memory without copying it through the GHC heap.
--   * All chunks have the same size, except possibly the last one.
--   * The provided file handle must support seeking, else you'll get an exception.
-- 
--   TODO: close file when done.
--
fileSourcesRecords 
        :: [FilePath]           -- ^ File paths.
        -> Int                  -- ^ Size of chunk to read in bytes.
        -> (Word8 -> Bool)      -- ^ Detect the end of a record.        
        -> IO ()                -- ^ Action to perform if we can't get a whole record.
        -> IO (Sources Int IO (Vector F Word8))

fileSourcesRecords filePaths len pSep aFail
 = do   hs      <- mapM (flip openBinaryFile ReadMode) filePaths
        hSourcesRecords hs len pSep aFail
{-# NOINLINE fileSourcesRecords #-}
--  NOINLINE because the chunks should be big enough to not require fusion,
--           and we don't want to release the code for 'openBinaryFile'.


-- | Like `fileSourceRecords`, but taking an existing file handle.
hSourcesRecords 
        :: [Handle]             -- ^ File handles.
        -> Int                  -- ^ Size of chunk to read in bytes.
        -> (Word8 -> Bool)      -- ^ Detect the end of a record.        
        -> IO ()                -- ^ Action to perform if we can't get a whole record.
        -> IO (Sources Int IO (Vector F Word8))

hSourcesRecords hs len pSep aFail
 = return $ Sources (P.length hs) pull_hSourceRecordsF
 where  
        pull_hSourceRecordsF (IIx i _) eat eject
         =  hIsEOF (hs !! i) >>= \eof
         -> if eof
             -- We're at the end of the file.
             then eject

             else do
                -- Read a new chunk from the file.
                arr      <- hGetArray (hs !! i) len

                -- Find the end of the last record in the file.
                let !mLenSlack  = findIndex pSep (R.reverse arr)

                case mLenSlack of
                 -- If we couldn't find the end of record then apply the failure action.
                 Nothing        -> aFail

                 -- Work out how long the record is.
                 Just lenSlack
                  -> do let !lenArr     = size (extent arr)
                        let !ixSplit    = lenArr - lenSlack

                        -- Seek the file to just after the last complete record.
                        hSeek (hs !! i) RelativeSeek (fromIntegral $ negate lenSlack)

                        -- Eat complete records at the start of the chunk.
                        eat $ window (Z :. 0) (Z :. ixSplit) arr
        {-# INLINE pull_hSourceRecordsF #-}
{-# INLINE [2] hSourcesRecords #-}


-- Sink Bytes -------------------------------------------------------------------------------------
-- | Write chunks of data to the given files.
--
--   TODO: close file when finished.
--
fileSinksBytes
        :: [FilePath] -> IO (Sinks Int IO (Vector F Word8))

fileSinksBytes filePaths
 = do   hs      <- mapM (flip openBinaryFile WriteMode) filePaths
        hSinksBytes hs
{-# NOINLINE fileSinksBytes #-}
--  NOINLINE because the chunks should be big enough to not require fusion,
--           and we don't want to release the code for 'openBinaryFile'.


-- | Write chunks of data to the given file handles.
hSinksBytes :: [Handle] -> IO (Sinks Int IO (Vector F Word8))
hSinksBytes !hs
 = do   let push_hSinkBytesF (IIx i _) !chunk
                = hPutArray (hs !! i) chunk
            {-# NOINLINE push_hSinkBytesF #-}

        let eject_hSinkBytesF _
                = return ()
            {-# INLINE eject_hSinkBytesF #-}

        return  $ Sinks (P.length hs) push_hSinkBytesF eject_hSinkBytesF
{-# INLINE [2] hSinksBytes #-}
