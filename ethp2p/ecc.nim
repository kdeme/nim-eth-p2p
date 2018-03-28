#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements `libsecp256k1` ECC/ECDH functions

import secp256k1, hexdump, nimcrypto/sysrand, nimcrypto/utils

const
  KeyLength* = 32
  PublicKeyLength* = 64
  SignatureLength* = 65


type
  EccContext* = ref object of RootRef
    context*: ptr secp256k1_context
    error*: string

  EccStatus* = enum
    Success,  ## Operation was successful
    Error     ## Operation failed

  PublicKey* = secp256k1_pubkey
    ## Representation of public key

  PrivateKey* = array[KeyLength, byte]
    ## Representation of secret key

  SharedSecret* = array[KeyLength, byte]
    ## Representation of ECDH shared secret

  Nonce* = array[KeyLength, byte]
    ## Representation of nonce

  RawPublickey* = object
    ## Representation of serialized public key
    header*: byte
    data*: array[KeyLength * 2, byte]

  KeyPair* = object
    ## Representation of private/public keys pair
    seckey*: PrivateKey
    pubkey*: PublicKey

  Signature* = secp256k1_ecdsa_recoverable_signature
    ## Representation of signature

  RawSignature* = object
    ## Representation of serialized signature
    data*: array[KeyLength * 2 + 1, byte]

  Secp256k1Exception* = object of Exception
    ## Exceptions generated by `libsecp256k1`
  EccException* = object of Exception
    ## Exception generated by this module

var eccContext* {.threadvar.}: EccContext
  ## Thread local variable which holds current context

proc illegalCallback(message: cstring; data: pointer) {.cdecl.} =
  let ctx = cast[EccContext](data)
  ctx.error = $message

proc errorCallback(message: cstring, data: pointer) {.cdecl.} =
  let ctx = cast[EccContext](data)
  ctx.error = $message

proc newEccContext*(): EccContext =
  ## Create new `EccContext`.
  result = new EccContext
  let flags = cuint(SECP256K1_CONTEXT_VERIFY or SECP256K1_CONTEXT_SIGN)
  result.context = secp256k1_context_create(flags)
  secp256k1_context_set_illegal_callback(result.context, illegalCallback,
                                         cast[pointer](result))
  secp256k1_context_set_error_callback(result.context, errorCallback,
                                       cast[pointer](result))
  result.error = ""

proc getSecpContext*(): ptr secp256k1_context =
  ## Get current `secp256k1_context`
  if isNil(eccContext):
    eccContext = newEccContext()
  result = eccContext.context

proc getEccContext*(): EccContext =
  ## Get current `EccContext`
  if isNil(eccContext):
    eccContext = newEccContext()
  result = eccContext

template raiseSecp256k1Error*() =
  ## Raises `libsecp256k1` error as exception
  let mctx = getEccContext()
  if len(mctx.error) > 0:
    var msg = mctx.error
    mctx.error.setLen(0)
    raise newException(Secp256k1Exception, msg)

proc eccErrorMsg*(): string =
  let mctx = getEccContext()
  result = mctx.error

proc setErrorMsg*(m: string) =
  let mctx = getEccContext()
  mctx.error = m

proc getRaw*(pubkey: PublicKey): RawPublickey =
  ## Converts public key `pubkey` to serialized form of `secp256k1_pubkey`.
  var length = csize(sizeof(RawPublickey))
  let ctx = getSecpContext()
  if secp256k1_ec_pubkey_serialize(ctx, cast[ptr cuchar](addr result),
                                   addr length, unsafeAddr pubkey,
                                   SECP256K1_EC_UNCOMPRESSED) != 1:
    raiseSecp256k1Error()
  if length != 65:
    raise newException(EccException, "Invalid public key length!")
  if result.header != 0x04'u8:
    raise newException(EccException, "Invalid public key header!")

proc getRaw*(s: Signature): RawSignature =
  ## Converts signature `s` to serialized form.
  let ctx = getSecpContext()
  var recid = cint(0)
  if secp256k1_ecdsa_recoverable_signature_serialize_compact(
    ctx, cast[ptr cuchar](unsafeAddr result), addr recid, unsafeAddr s) != 1:
    raiseSecp256k1Error()
  result.data[64] = uint8(recid)

proc signMessage*(seckey: PrivateKey, data: ptr byte, length: int,
                  sig: var Signature): EccStatus =
  ## Sign message pointed by `data` with size `length` and save signature to
  ## `sig`.
  let ctx = getSecpContext()
  if secp256k1_ecdsa_sign_recoverable(ctx, addr sig,
                                      cast[ptr cuchar](data),
                                      cast[ptr cuchar](unsafeAddr seckey[0]),
                                      nil, nil) != 1:
    return(Error)
  return(Success)

proc signMessage*[T](seckey: PrivateKey, data: openarray[T],
                     sig: var Signature, ostart: int = 0,
                     ofinish: int = -1): EccStatus =
  ## Sign message ``data``[`soffset`..`eoffset`] and store result into `sig`.
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(T)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo >= len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if len(data) < KeyLength or length < KeyLength:
    setErrorMsg("There no reason to sign this message!")
    return(Error)
  result = signMessage(seckey, cast[ptr byte](unsafeAddr data[so]),
                       length, sig)

proc recoverSignatureKey*(data: ptr byte, length: int, message: ptr byte,
                          pubkey: var PublicKey): EccStatus =
  ## Check signature and return public key from `data` with size `length` and
  ## `message`.
  let ctx = getSecpContext()
  var s: secp256k1_ecdsa_recoverable_signature
  if length >= 65:
    var recid = cint(cast[ptr UncheckedArray[byte]](data)[KeyLength * 2])
    if secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, addr s,
                                                         cast[ptr cuchar](data),
                                                           recid) != 1:
      return(Error)

    if secp256k1_ecdsa_recover(ctx, addr pubkey, addr s,
                               cast[ptr cuchar](message)) != 1:
      setErrorMsg("Message signature verification failed!")
      return(Error)
    return(Success)
  else:
    setErrorMsg("Incorrect signature size")
    return(Error)

proc recoverSignatureKey*[A, B](data: openarray[A],
                                message: openarray[B],
                                pubkey: var PublicKey,
                                ostart: int = 0,
                                ofinish: int = -1): EccStatus =
  ## Check signature in ``data``[`soffset`..`eoffset`] and recover public key
  ## from signature to ``pubkey`` using message `message`.
  if len(message) == 0:
    setErrorMsg("Message could not be empty!")
    return(Error)
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(A)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo > len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if length < sizeof(RawSignature) or len(data) < sizeof(RawSignature):
    setErrorMsg("Invalid signature size!")
    return(Error)
  result = recoverSignatureKey(cast[ptr byte](unsafeAddr data[so]), length,
                               cast[ptr byte](unsafeAddr message[0]), pubkey)

proc ecdhAgree*(seckey: PrivateKey, pubkey: PublicKey,
                secret: var SharedSecret): EccStatus =
  ## Calculate ECDH shared secret
  var res: array[KeyLength + 1, byte]
  let ctx = getSecpContext()
  if secp256k1_ecdh_raw(ctx, cast[ptr cuchar](addr res),
                        unsafeAddr pubkey,
                        cast[ptr cuchar](unsafeAddr seckey)) != 1:
    return(Error)
  copyMem(addr secret[0], addr res[1], KeyLength)
  return(Success)

proc getPublicKey*(seckey: PrivateKey): PublicKey =
  ## Return public key for private key `seckey`.
  let ctx = getSecpContext()
  if secp256k1_ec_pubkey_create(ctx, addr result,
                                cast[ptr cuchar](unsafeAddr seckey[0])) != 1:
    raiseSecp256k1Error()


proc recoverPublicKey*(data: ptr byte, length: int,
                       pubkey: var PublicKey): EccStatus =
  ## Unserialize public key from `data` pointer and size `length` and'
  ## set `pubkey`.
  let ctx = getSecpContext()
  if length < sizeof(PublicKey):
    setErrorMsg("Invalid public key!")
    return(Error)
  var rawkey: RawPublickey
  rawkey.header = 0x04 # mark key with COMPRESSED flag
  copyMem(addr rawkey.data[0], data, len(rawkey.data))
  if secp256k1_ec_pubkey_parse(ctx, addr pubkey,
                               cast[ptr cuchar](addr rawkey),
                               sizeof(RawPublickey)) != 1:
    return(Error)
  return(Success)

proc recoverPublicKey*[T](data: openarray[T], pubkey: var PublicKey,
                          ostart: int = 0, ofinish: int = -1, ): EccStatus =
  ## Unserialize public key from openarray[T] `data`, from position `ostart` to
  ## position `ofinish` and save it to `pubkey`.
  let so = ostart
  let eo = if ofinish == -1: (len(data) - 1) else: ofinish
  let length = (eo - so + 1) * sizeof(T)
  # We don't need to check `so` because compiler will do it for `data[so]`.
  if eo > len(data):
    setErrorMsg("Index is out of bounds!")
    return(Error)
  if length < sizeof(PublicKey) or len(data) < sizeof(PublicKey):
    setErrorMsg("Invalid public key size!")
    return(Error)
  result = recoverPublicKey(cast[ptr byte](unsafeAddr data[so]), length,
                            pubkey)

proc newPrivateKey*(): PrivateKey =
  ## Generates new secret key.
  let ctx = getSecpContext()
  while true:
    if randomBytes(addr result[0], KeyLength) == KeyLength:
      if secp256k1_ec_seckey_verify(ctx, cast[ptr cuchar](addr result[0])) == 1:
        break

proc newKeyPair*(): KeyPair =
  ## Generates new private and public key.
  result.seckey = newPrivateKey()
  result.pubkey = result.seckey.getPublicKey()

proc getPrivateKey*(hexstr: string): PrivateKey =
  ## Set secret key from hexadecimal string representation.
  let ctx = getSecpContext()
  var o = fromHex(stripSpaces(hexstr))
  if len(o) < KeyLength:
    raise newException(EccException, "Invalid private key!")
  copyMem(addr result[0], unsafeAddr o[0], KeyLength)
  if secp256k1_ec_seckey_verify(ctx, cast[ptr cuchar](addr result[0])) != 1:
    raise newException(EccException, "Invalid private key!")

proc getPublicKey*(hexstr: string): PublicKey =
  ## Set public key from hexadecimal string representation.
  var o = fromHex(stripSpaces(hexstr))
  if recoverPublicKey(o, result) != Success:
    raise newException(EccException, "Invalid public key!")

proc dump*(s: openarray[byte], c: string = ""): string =
  ## Return hexadecimal dump of array `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  if len(s) > 0:
    result &= dumpHex(unsafeAddr s[0], len(s))
  else:
    result &= "[]"

proc dump*(s: PublicKey, c: string = ""): string =
  ## Return hexadecimal dump of public key `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0], sizeof(secp256k1_pubkey))

proc dump*(s: RawSignature, c: string = ""): string =
  ## Return hexadecimal dump of serialized signature `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0], sizeof(RawSignature))

proc dump*(s: RawPublickey, c: string = ""): string =
  ## Return hexadecimal dump of serialized public key `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s, sizeof(RawSignature))

proc dump*(s: secp256k1_ecdsa_recoverable_signature, c: string = ""): string =
  ## Return hexadecimal dump of signature `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(unsafeAddr s.data[0],
                    sizeof(secp256k1_ecdsa_recoverable_signature))

proc dump*(p: pointer, s: int, c: string = ""): string =
  ## Return hexadecimal dump of memory blob `p` and size `s`.
  result = if len(c) > 0: c & "=>\n" else: ""
  result &= dumpHex(p, s)

when isMainModule:
  import nimcrypto/hash, nimcrypto/keccak

  proc compare(x: openarray[byte], y: openarray[byte]): bool =
    result = len(x) == len(y)
    if result:
      for i in 0..(len(x) - 1):
        if x[i] != y[i]:
          result = false
          break

  block:
    # ECDHE test vectors
    # Copied from
    # https://github.com/ethereum/py-evm/blob/master/tests/p2p/test_ecies.py#L19
    const privateKeys = [
      "332143e9629eedff7d142d741f896258f5a1bfab54dab2121d3ec5000093d74b",
      "7ebbc6a8358bc76dd73ebc557056702c8cfc34e5cfcd90eb83af0347575fd2ad"
    ]
    const publicKeys = [
      """f0d2b97981bd0d415a843b5dfe8ab77a30300daab3658c578f2340308a2da1a07
         f0821367332598b6aa4e180a41e92f4ebbae3518da847f0b1c0bbfe20bcf4e1""",
      """83ede0f19c3c98649265956a4193677b14c338a22de2086a08d84e4446fe37e4e
         233478259ec90dbeef52f4f6c890f8c38660ec7b61b9d439b8a6d1c323dc025"""
    ]
    const sharedSecrets = [
      "ee1418607c2fcfb57fda40380e885a707f49000a5dda056d828b7d9bd1f29a08",
      "167ccc13ac5e8a26b131c3446030c60fbfac6aa8e31149d0869f93626a4cdf62"
    ]
    var secret: array[KeyLength, byte]
    for i in 0..1:
      var s = privateKeys[i].getPrivateKey()
      var p = publicKeys[i].getPublicKey()
      doAssert(ecdhAgree(s, p, secret) == Success)
      var check = fromHex(stripSpaces(sharedSecrets[i]))
      doAssert(compare(check, secret))

  block:
    # ECDHE test vectors
    # Copied from https://github.com/ethereum/cpp-ethereum/blob/develop/test/unittests/libdevcrypto/crypto.cpp#L394
    var expect = """
      8ac7e464348b85d9fdfc0a81f2fdc0bbbb8ee5fb3840de6ed60ad9372e718977"""
    var secret: array[KeyLength, byte]
    var s = keccak256.digest("ecdhAgree").data
    var p = s.getPublicKey()
    doAssert(ecdhAgree(s, p, secret) == Success)
    var check = fromHex(stripSpaces(expect))
    doAssert(compare(check, secret))

  block:
    # ECDHE test vectors
    # Copied from https://github.com/ethereum/cpp-ethereum/blob/2409d7ec7d34d5ff5770463b87eb87f758e621fe/test/unittests/libp2p/rlpx.cpp#L425
    var s0 = """
      332143e9629eedff7d142d741f896258f5a1bfab54dab2121d3ec5000093d74b"""
    var p0 = """
      f0d2b97981bd0d415a843b5dfe8ab77a30300daab3658c578f2340308a2da1a0
      7f0821367332598b6aa4e180a41e92f4ebbae3518da847f0b1c0bbfe20bcf4e1"""
    var e0 = """
      ee1418607c2fcfb57fda40380e885a707f49000a5dda056d828b7d9bd1f29a08"""
    var secret: array[KeyLength, byte]
    var s = getPrivateKey(s0)
    var p = getPublicKey(p0)
    var check = fromHex(stripSpaces(e0))
    doAssert(ecdhAgree(s, p, secret) == Success)
    doAssert(compare(check, secret))

  block:
    # ECDSA test vectors
    # Copied from https://github.com/ethereum/cpp-ethereum/blob/develop/test/unittests/libdevcrypto/crypto.cpp#L132
    var signature = """
      b826808a8c41e00b7c5d71f211f005a84a7b97949d5e765831e1da4e34c9b8295d
      2a622eee50f25af78241c1cb7cfff11bcf2a13fe65dee1e3b86fd79a4e3ed000"""
    var pubkey = """
      e40930c838d6cca526795596e368d16083f0672f4ab61788277abfa23c3740e1cc
      84453b0b24f49086feba0bd978bb4446bae8dff1e79fcc1e9cf482ec2d07c3"""
    var check1 = fromHex(stripSpaces(signature))
    var check2 = fromHex(stripSpaces(pubkey))
    var sig: Signature
    var key: PublicKey
    var s = keccak256.digest("sec").data
    var m = keccak256.digest("msg").data
    doAssert(signMessage(s, m, sig) == Success)
    var sersig = sig.getRaw().data
    doAssert(recoverSignatureKey(sersig, m, key) == Success)
    var serkey = key.getRaw().data
    doAssert(compare(sersig, check1))
    doAssert(compare(serkey, check2))

  block:
    # signature test
    var rkey: PublicKey
    var sig: Signature
    for i in 1..100:
      var m = newPrivateKey()
      var s = newPrivateKey()
      var key = s.getPublicKey()
      doAssert(signMessage(s, m, sig) == Success)
      var sersig = sig.getRaw().data
      doAssert(recoverSignatureKey(sersig, m, rkey) == Success)
      doAssert(key == rkey)

  block:
    # key create/recovery test
    var rkey: PublicKey
    for i in 1..100:
      var s = newPrivateKey()
      var key = s.getPublicKey()
      doAssert(recoverPublicKey(key.getRaw().data, rkey) == Success)
      doAssert(key == rkey)

  block:
    # ECDHE shared secret test
    var secret1, secret2: SharedSecret
    for i in 1..100:
      var aliceSecret = newPrivateKey()
      var alicePublic = aliceSecret.getPublicKey()
      var bobSecret = newPrivateKey()
      var bobPublic = bobSecret.getPublicKey()
      doAssert(ecdhAgree(aliceSecret, bobPublic, secret1) == Success)
      doAssert(ecdhAgree(bobSecret, alicePublic, secret2) == Success)
      doAssert(secret1 == secret2)
