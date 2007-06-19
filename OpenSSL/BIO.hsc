{- -*- haskell -*- -}

-- #hide

{- --------------------------------------------------------------------------- -}
{-                                                                             -}
{-                           FOR INTERNAL USE ONLY                             -}
{-                                                                             -}
{- When I firstly saw the manpage of bio(3), it looked like a great API. I ac- -}
{- tually wrote a wrapper and even wrote a document. What a pain!              -}
{-                                                                             -}
{- Now I realized that BIOs aren't necessary to we Haskell hackers. Their fun- -}
{- ctionalities overlaps with Haskell's own I/O system. The only thing which   -}
{- wasn't available without bio(3) -- at least I thought so -- was the         -}
{- BIO_f_base64(3), but I found an undocumented API for the Base64 codec. So I -}
{- decided to bury all the OpenSSL.BIO module. The game is over.               -}
{- --------------------------------------------------------------------------- -}


#include "HsOpenSSL.h"

-- |A BIO is an I\/O abstraction, it hides many of the underlying I\/O
-- details from an application, if you are writing a pure C
-- application...
--
-- I know, we are hacking on Haskell so BIO components like BIO_s_file
-- are hardly needed. But for filter BIOs, such as BIO_f_base64 and
-- BIO_f_cipher, they should be useful too to us.

module OpenSSL.BIO
    ( -- * Type
      BIO
    , BIO_

      -- * BIO chaning
    , bioPush
    , (==>)
    , (<==)
    , bioJoin

      -- * BIO control operations
    , bioFlush
    , bioReset
    , bioEOF

      -- * BIO I\/O functions
    , bioRead
    , bioReadBS
    , bioReadLBS
    , bioGets
    , bioGetsBS
    , bioGetsLBS
    , bioWrite
    , bioWriteBS
    , bioWriteLBS

      -- * Base64 BIO filter
    , newBase64

      -- * Buffering BIO filter
    , newBuffer

      -- * Symmetric cipher BIO filter
    , newCipher

      -- * Message digest BIO filter
    , newMD

      -- * Memory BIO sink\/source
    , newMem
    , newConstMem
    , newConstMemBS
    , newConstMemLBS

      -- * Null data BIO sink\/source
    , newNullBIO
    )
    where

import           Control.Monad
import qualified Data.ByteString            as B
import           Data.ByteString.Base
import qualified Data.ByteString.Char8      as B8
import qualified Data.ByteString.Lazy.Char8 as L8
import           Foreign                    hiding (new)
import           Foreign.C
import qualified GHC.ForeignPtr             as GF
import           OpenSSL.EVP.Cipher
import           OpenSSL.EVP.Digest
import           OpenSSL.Utils
import           System.IO.Unsafe

{- bio ---------------------------------------------------------------------- -}

type BioMethod  = Ptr BIO_METHOD
data BIO_METHOD = BIO_METHOD

-- |@BIO@ is a @ForeignPtr@ to an opaque BIO object. They are created by newXXX actions.
type BIO  = ForeignPtr BIO_
data BIO_ = BIO_

foreign import ccall unsafe "BIO_new"
        _new :: Ptr BIO_METHOD -> IO (Ptr BIO_)

foreign import ccall unsafe "&BIO_free"
        _free :: FunPtr (Ptr BIO_ -> IO ())

foreign import ccall unsafe "BIO_push"
        _push :: Ptr BIO_ -> Ptr BIO_ -> IO (Ptr BIO_)

foreign import ccall unsafe "HsOpenSSL_BIO_set_flags"
        _set_flags :: Ptr BIO_ -> Int -> IO ()

foreign import ccall unsafe "HsOpenSSL_BIO_should_retry"
        _should_retry :: Ptr BIO_ -> IO Int


new :: BioMethod -> IO BIO
new method
    = do ptr <- _new method >>= failIfNull
         newForeignPtr _free ptr


-- a の後ろに b を付ける。a の參照だけ保持してそこに書き込む事も、b の
-- 參照だけ保持してそこから讀み出す事も、兩方考へられるので、双方の
-- ForeignPtr が双方を touch する。參照カウント方式ではないから循環參照
-- しても問題無い。

-- |Computation of @'bioPush' a b@ connects @b@ behind @a@.
--
-- Example:
--
-- > do b64 <- newBase64 True
-- >    mem <- newMem
-- >    bioPush b64 mem
-- >
-- >    -- Encode some text in Base64 and write the result to the
-- >    -- memory buffer.
-- >    bioWrite b64 "Hello, world!"
-- >    bioFlush b64
-- >
-- >    -- Then dump the memory buffer.
-- >    bioRead mem >>= putStrLn
--
bioPush :: BIO -> BIO -> IO ()
bioPush a b
    = withForeignPtr a $ \ aPtr ->
      withForeignPtr b $ \ bPtr ->
      do _push aPtr bPtr
         GF.addForeignPtrConcFinalizer a $ touchForeignPtr b
         GF.addForeignPtrConcFinalizer b $ touchForeignPtr a
         return ()

-- |@a '==>' b@ is an alias to @'bioPush' a b@.
(==>) :: BIO -> BIO -> IO ()
(==>) = bioPush

-- |@a '<==' b@ is an alias to @'bioPush' b a@.
(<==) :: BIO -> BIO -> IO ()
(<==) = flip bioPush


-- |@'bioJoin' [bio1, bio2, ..]@ connects many BIOs at once.
bioJoin :: [BIO] -> IO ()
bioJoin []       = return ()
bioJoin (_:[])   = return ()
bioJoin (a:b:xs) = bioPush a b >> bioJoin (b:xs)


setFlags :: BIO -> Int -> IO ()
setFlags bio flags
    = withForeignPtr bio $ \ bioPtr ->
      _set_flags bioPtr flags

bioShouldRetry :: BIO -> IO Bool
bioShouldRetry bio
    = withForeignPtr bio $ \ bioPtr ->
      _should_retry bioPtr >>= return . (/= 0)


{- ctrl --------------------------------------------------------------------- -}

foreign import ccall unsafe "HsOpenSSL_BIO_flush"
        _flush :: Ptr BIO_ -> IO Int

foreign import ccall unsafe "HsOpenSSL_BIO_reset"
        _reset :: Ptr BIO_ -> IO Int

foreign import ccall unsafe "HsOpenSSL_BIO_eof"
        _eof :: Ptr BIO_ -> IO Int

-- |@'bioFlush' bio@ normally writes out any internally buffered data,
-- in some cases it is used to signal EOF and that no more data will
-- be written.
bioFlush :: BIO -> IO ()
bioFlush bio
    = withForeignPtr bio $ \ bioPtr ->
      _flush bioPtr >>= failIf (/= 1) >> return ()

-- |@'bioReset' bio@ typically resets a BIO to some initial state.
bioReset :: BIO -> IO ()
bioReset bio
    = withForeignPtr bio $ \ bioPtr ->
      _reset bioPtr >> return () -- BIO_reset の戻り値は全 BIO で共通で
                                 -- ないのでエラーチェックが出來ない。

-- |@'bioEOF' bio@ returns 1 if @bio@ has read EOF, the precise
-- meaning of EOF varies according to the BIO type.
bioEOF :: BIO -> IO Bool
bioEOF bio
    = withForeignPtr bio $ \ bioPtr ->
      _eof bioPtr >>= return . (== 1)


{- I/O ---------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_read"
        _read :: Ptr BIO_ -> Ptr CChar -> Int -> IO Int

foreign import ccall unsafe "BIO_gets"
        _gets :: Ptr BIO_ -> Ptr CChar -> Int -> IO Int

foreign import ccall unsafe "BIO_write"
        _write :: Ptr BIO_ -> Ptr CChar -> Int -> IO Int

-- |@'bioRead' bio@ lazily reads all data in @bio@.
bioRead :: BIO -> IO String
bioRead bio
    = liftM L8.unpack $ bioReadLBS bio

-- |@'bioReadBS' bio len@ attempts to read @len@ bytes from @bio@,
-- then return a ByteString. The actual length of result may be less
-- than @len@.
bioReadBS :: BIO -> Int -> IO ByteString
bioReadBS bio maxLen
    = withForeignPtr bio $ \ bioPtr ->
      createAndTrim maxLen $ \ buf ->
      _read bioPtr (unsafeCoercePtr buf) maxLen >>= interpret
    where
      interpret :: Int -> IO Int
      interpret n
          | n ==  0   = return 0
          | n == -1   = return 0
          | n <  -1   = raiseOpenSSLError
          | otherwise = return n

-- |@'bioReadLBS' bio@ lazily reads all data in @bio@, then return a
-- LazyByteString.
bioReadLBS :: BIO -> IO LazyByteString
bioReadLBS bio = lazyRead >>= return . LPS
    where
      chunkSize = 32 * 1024
      
      lazyRead = unsafeInterleaveIO loop

      loop = do bs <- bioReadBS bio chunkSize
                if B.null bs then
                    do isEOF <- bioEOF bio
                       if isEOF then
                           return []
                         else
                           do shouldRetry <- bioShouldRetry bio
                              if shouldRetry then
                                  loop
                                else
                                  fail "bioReadLBS: got null but isEOF=False, shouldRetry=False"
                  else
                    do bss <- lazyRead
                       return (bs:bss)

-- |@'bioGets' bio len@ normally attempts to read one line of data
-- from @bio@ of maximum length @len@. There are exceptions to this
-- however, for example 'bioGets' on a digest BIO will calculate and
-- return the digest and other BIOs may not support 'bioGets' at all.
bioGets :: BIO -> Int -> IO String
bioGets bio maxLen
    = liftM B8.unpack (bioGetsBS bio maxLen)

-- |'bioGetsBS' does the same as 'bioGets' but returns ByteString.
bioGetsBS :: BIO -> Int -> IO ByteString
bioGetsBS bio maxLen
    = withForeignPtr bio $ \ bioPtr ->
      createAndTrim maxLen $ \ buf ->
      _gets bioPtr (unsafeCoercePtr buf) maxLen >>= interpret
    where
      interpret :: Int -> IO Int
      interpret n
          | n ==  0   = return 0
          | n == -1   = return 0
          | n <  -1   = raiseOpenSSLError
          | otherwise = return n

-- |'bioGetsLBS' does the same as 'bioGets' but returns
-- LazyByteString.
bioGetsLBS :: BIO -> Int -> IO LazyByteString
bioGetsLBS bio maxLen
    = bioGetsBS bio maxLen >>= \ bs -> (return . LPS) [bs]

-- |@'bioWrite' bio str@ lazily writes entire @str@ to @bio@. The
-- string doesn't necessarily have to be finite.
bioWrite :: BIO -> String -> IO ()
bioWrite bio str
    = (return . L8.pack) str >>= bioWriteLBS bio

-- |@'bioWriteBS' bio bs@ writes @bs@ to @bio@.
bioWriteBS :: BIO -> ByteString -> IO ()
bioWriteBS bio bs
    = withForeignPtr bio $ \ bioPtr ->
      unsafeUseAsCStringLen bs $ \ (buf, len) ->
      _write bioPtr buf len >>= interpret
    where
      interpret :: Int -> IO ()
      interpret n
          | n == B.length bs = return ()
          | n == -1          = bioWriteBS bio bs -- full retry
          | n <  -1          = raiseOpenSSLError
          | otherwise        = bioWriteBS bio (B.drop n bs) -- partial retry

-- |@'bioWriteLBS' bio lbs@ lazily writes entire @lbs@ to @bio@. The
-- string doesn't necessarily have to be finite.
bioWriteLBS :: BIO -> LazyByteString -> IO ()
bioWriteLBS bio (LPS chunks)
    = mapM_ (bioWriteBS bio) chunks


{- base64 ------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_f_base64"
        f_base64 :: IO BioMethod

foreign import ccall unsafe "HsOpenSSL_BIO_FLAGS_BASE64_NO_NL"
        _FLAGS_BASE64_NO_NL :: Int

-- |@'newBase64' noNL@ creates a Base64 BIO filter. This is a filter
-- bio that base64 encodes any data written through it and decodes any
-- data read through it.
--
-- If @noNL@ flag is True, the filter encodes the data all on one line
-- or expects the data to be all on one line.
--
-- Base64 BIOs do not support 'bioGets'.
--
-- 'bioFlush' on a Base64 BIO that is being written through is used to
-- signal that no more data is to be encoded: this is used to flush
-- the final block through the BIO.
newBase64 :: Bool -> IO BIO
newBase64 noNL
    = do bio <- new =<< f_base64
         when noNL $ setFlags bio _FLAGS_BASE64_NO_NL
         return bio


{- buffer ------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_f_buffer"
        f_buffer :: IO BioMethod

foreign import ccall unsafe "HsOpenSSL_BIO_set_buffer_size"
        _set_buffer_size :: Ptr BIO_ -> Int -> IO Int


-- |@'newBuffer' mBufSize@ creates a buffering BIO filter. Data
-- written to a buffering BIO is buffered and periodically written to
-- the next BIO in the chain. Data read from a buffering BIO comes
-- from the next BIO in the chain.
--
-- Buffering BIOs support 'bioGets'.
--
-- Calling 'bioReset' on a buffering BIO clears any buffered data.
--
-- Question: When I created a BIO chain like this and attempted to
-- read from the buf, the buffering BIO weirdly behaved: BIO_read()
-- returned nothing, but both BIO_eof() and BIO_should_retry()
-- returned zero. I tried to examine the source code of
-- crypto\/bio\/bf_buff.c but it was too complicated to
-- understand. Does anyone know why this happens? The version of
-- OpenSSL was 0.9.7l.
--
-- > main = withOpenSSL $
-- >        do mem <- newConstMem "Hello, world!"
-- >           buf <- newBuffer Nothing
-- >           mem ==> buf
-- >
-- >           bioRead buf >>= putStrLn -- This fails, but why?
--
-- I am being depressed for this unaccountable failure.
--
newBuffer :: Maybe Int -- ^ Explicit buffer size (@Just n@) or the
                       -- default size (@Nothing@).
          -> IO BIO
newBuffer bufSize
    = do bio <- new =<< f_buffer
         case bufSize of
           Just n  -> withForeignPtr bio $ \ bioPtr ->
                      _set_buffer_size bioPtr n
                           >>= failIf (/= 1) >> return ()
           Nothing -> return ()
         return bio

{- cipher ------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_f_cipher"
        f_cipher :: IO BioMethod

foreign import ccall unsafe "BIO_set_cipher"
        _set_cipher :: Ptr BIO_ -> EvpCipher -> CString -> CString -> Int -> IO ()

-- |@'newCipher' cipher key iv mode@ creates a symmetric cipher BIO
-- filter. If @mode@ is 'OpenSSL.EVP.Cipher.Encrypt', this filter
-- encrypts any data written through it and encrypts any data read
-- through it. If @mode@ is 'OpenSSL.EVP.Cipher.Decrypt', it does the
-- opposite to 'OpenSSL.EVP.Cipher.Encrypt'.
--
-- Cipher BIOs do not support 'bioGets'.
--
-- 'bioFlush' on an encryption BIO that is being written through is
-- used to signal that no more data is to be encrypted: this is used
-- to flush and possibly pad the final block through the BIO.
--
-- When reading from an decryption BIO the final block is
-- automatically decrypted and checked when EOF is detected.
newCipher :: EvpCipher -> String -> String -> CryptoMode -> IO BIO
newCipher cipher key iv mode
    = do bio <- new =<< f_cipher
         withForeignPtr bio $ \ bioPtr ->
             withCString key $ \ keyPtr ->
                 withCString iv $ \ ivPtr ->
                     _set_cipher bioPtr cipher keyPtr ivPtr (cryptoModeToInt mode)
         return bio


{- md ----------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_f_md"
        f_md :: IO BioMethod

foreign import ccall unsafe "HsOpenSSL_BIO_set_md"
        _set_md :: Ptr BIO_ -> Ptr EVP_MD -> IO Int

-- |@'newMD' md@ creates a message digest BIO filter. This is a filter
-- BIO that digests any data passed through it.
--
-- Any data written or read through a digest BIO using 'bioRead' and
-- 'bioWrite' is digested.
--
-- 'bioGets', if its size parameter is large enough finishes the
-- digest calculation and returns the digest value. The length of
-- digest value can be retrieved using 'OpenSSL.EVP.Digest.mdSize'.
--
-- 'bioReset' reinitializes a digest BIO.
newMD :: EvpMD -> IO BIO
newMD md
    = do bio <- new =<< f_md
         withForeignPtr bio $ \ bioPtr ->
             do _set_md bioPtr md >>= failIf (/= 1)
                return bio


{- mem ---------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_s_mem"
        s_mem :: IO BioMethod

foreign import ccall unsafe "BIO_new_mem_buf"
        _new_mem_buf :: Ptr CChar -> Int -> IO (Ptr BIO_)


-- |@'newMem'@ creates a memory BIO sink\/source. Any data written to
-- a memory BIO can be recalled by reading from it. Unless the memory
-- BIO is read only any data read from it is deleted from the BIO.
--
-- Memory BIOs support 'bioGets'.
--
-- Calling 'bioReset' on a erad write memory BIO clears any data in
-- it. On a read only BIO it restores the BIO to its original state
-- and the read only data can be read again.
--
-- 'bioEOF' is true if no data is in the BIO.
--
-- Every read from a read write memory BIO will remove the data just
-- read with an internal copy operation, if a BIO contains a lots of
-- data and it is read in small chunks the operation can be very
-- slow. The use of a read only memory BIO avoids this problem. If the
-- BIO must be read write then adding a buffering BIO ('newBuffer') to
-- the chain will speed up the process.
newMem :: IO BIO
newMem = s_mem >>= new

-- |@'newConstMem' str@ creates a read-only memory BIO source.
newConstMem :: String -> IO BIO
newConstMem str
    = (return . B8.pack) str >>= newConstMemBS

-- |@'newConstMemBS' bs@ is like 'newConstMem' but takes a ByteString.
newConstMemBS :: ByteString -> IO BIO
newConstMemBS bs
    = let (foreignBuf, off, len) = toForeignPtr bs
      in
        -- ByteString への參照を BIO の finalizer に持たせる。
        withForeignPtr foreignBuf $ \ buf ->
        do bioPtr <- _new_mem_buf (unsafeCoercePtr $ buf `plusPtr` off) len
                     >>= failIfNull

           bio <- newForeignPtr _free bioPtr
           GF.addForeignPtrConcFinalizer bio $ touchForeignPtr foreignBuf
           
           return bio

-- |@'newConstMemLBS' lbs@ is like 'newConstMem' but takes a
-- LazyByteString.
newConstMemLBS :: LazyByteString -> IO BIO
newConstMemLBS (LPS bss)
    = (return . B.concat) bss >>= newConstMemBS

{- null --------------------------------------------------------------------- -}

foreign import ccall unsafe "BIO_s_null"
        s_null :: IO BioMethod

-- |@'newNullBIO'@ creates a null BIO sink\/source. Data written to
-- the null sink is discarded, reads return EOF.
--
-- A null sink is useful if, for example, an application wishes to
-- digest some data by writing through a digest bio but not send the
-- digested data anywhere. Since a BIO chain must normally include a
-- source\/sink BIO this can be achieved by adding a null sink BIO to
-- the end of the chain.
newNullBIO :: IO BIO
newNullBIO = s_null >>= new