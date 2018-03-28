#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements Ethereum authentication

import endians
import ecc, ecies, rlp
import nimcrypto/sysrand, nimcrypto/hash, nimcrypto/utils, nimcrypto/hmac
import nimcrypto/rijndael, nimcrypto/keccak, nimcrypto/sha2
import hexdump

const
  SupportedRlpxVersion* = 4
  PlainAuthMessageLength* = 194
  PlainAuthAckMessageLength* = 97
  AuthMessageLength* = 307
  AuthAckMessageLength* = 210

type
  HandshakeFlag* = enum
    Initiator,      ## `Handshake` owner is connection initiator
    Responder,      ## `Handshake` owner is connection responder
    Eip8            ## Flag indicates that EIP-8 handshake is used

  AuthStatus* = enum
    Success,        ## Operation was successful
    RandomError,    ## Could not obtain random data
    EcdhError,      ## ECDH shared secret could not be calculated
    SignatureError, ## Signature could not be obtained
    EciesError,     ## ECIES encryption/decryption error
    InvalidPubKey,  ## Invalid public key
    InvalidAuth,    ## Invalid Authentication message
    InvalidAck,     ## Invalid Authentication ACK message
    RlpError,       ## Error while decoding RLP stream
    IncompleteError ## Data incomplete error

  Handshake* = object
    version: uint8
    flags: set[HandshakeFlag]
    host*: KeyPair
    ephemeral*: KeyPair
    remoteHPubkey*: PublicKey
    remoteEPubkey*: PublicKey
    initiatorNonce*: Nonce
    responderNonce*: Nonce

  ConnectionSecret* = object
    aesKey*: array[aes256.sizeKey, byte]
    macKey*: array[KeyLength, byte]
    egressMac*: array[keccak256.sizeDigest, byte]
    ingressMac*: array[keccak256.sizeDigest, byte]

  PlainAuthMessage* = array[PlainAuthMessageLength, byte]
  PlainAuthAckMessage* = array[PlainAuthAckMessageLength, byte]
  AuthMessage* = array[AuthMessageLength, byte]
  AuthAckMessage* = array[AuthAckMessageLength, byte]

  AuthException* = object of Exception

proc sxor[T](a: var openarray[T], b: openarray[T]) =
  assert(len(a) == len(b))
  for i in 0..(len(a) - 1):
    a[i] = a[i] xor b[i]

proc empty[T](v: openarray[T]): bool =
  var r: T
  for item in v:
    r = r + item
  result = (r == T(0))

proc move[T](dst: var openarray[T], src: openarray[T],
             dstx: int = 0, dsty: int = -1, srcx: int = 0, srcy: int = -1) =
  let sx = if srcx < 0: (len(src) + srcx) else: srcx
  let sy = if srcy < 0: (len(src) + srcy) else: srcy
  let dx = if dstx < 0: (len(dst) + dstx) else: dstx
  let dy = if dsty < 0: (len(dst) + dsty) else: dsty
  assert(sy - sx == dy - dx)
  moveMem(addr dst[dstx], unsafeAddr src[srcx], (dy - dx + 1) * sizeof(T))

proc newHandshake*(flags: set[HandshakeFlag] = {Initiator}): Handshake =
  var p: ptr byte
  result.flags = flags
  result.ephemeral = newKeyPair()

  if Initiator in flags:
    p = addr result.initiatorNonce[0]
  else:
    p = addr result.responderNonce[0]

  if randomBytes(p, KeyLength) != KeyLength:
    raise newException(AuthException, "Could not obtain random data!")

proc authMessage*(h: var Handshake,
                  pubkey: PublicKey,
                  output: var PlainAuthMessage): AuthStatus =
  ## Create plain preEIP8 authentication message.
  var secret: SharedSecret
  var signature: Signature
  var flag = byte(0x00)

  if ecdhAgree(h.host.seckey, pubkey, secret) != EccStatus.Success:
    return(EcdhError)

  if h.initiatorNonce.empty():
    if randomBytes(addr h.initiatorNonce[0], KeyLength) != KeyLength:
      return(RandomError)

  var xornonce = h.initiatorNonce
  xornonce.sxor(secret)

  if signMessage(h.ephemeral.seckey, xornonce, signature) != EccStatus.Success:
    return(SignatureError)

  copyMem(addr h.remoteHPubkey, unsafeAddr pubkey, sizeof(PublicKey))

  move(output, signature.getRaw().data, 0, 64)
  move(output, keccak256.digest(h.ephemeral.pubkey.getRaw().data).data, 65, 96)
  move(output, h.host.pubkey.getRaw().data, 97, 160)
  move(output, h.initiatorNonce, 161, 192)
  output[193] = flag

proc authAckMessage*(h: var Handshake,
                     output: var PlainAuthAckMessage): AuthStatus =
  if EIP8 in h.flags:
    discard
  else:
    move(output, h.ephemeral.pubkey.getRaw().data, 0, 63)
    move(output, h.responderNonce, 64, 95)
    output[96] = byte(0x00)

proc encryptAuthMessage*(input: ptr byte, inputlen: int,
                         output: ptr byte, outputlen: int,
                         pubkey: PublicKey, shmac: ptr byte = nil,
                         shlen: int = 0): AuthStatus =
  result = Success
  if eciesEncrypt(input, output, inputlen, outputlen,
                  pubkey, shmac, shlen) != EciesStatus.Success:
    result = EciesError

proc encryptAuthMessage*(input: PlainAuthMessage,
                         output: var AuthMessage,
                         pubkey: PublicKey): AuthStatus =
  result = Success
  result = encryptAuthMessage(unsafeAddr input[0], PlainAuthMessageLength,
                              addr output[0], AuthMessageLength, pubkey)

proc decryptAuthMessage*(input: ptr byte, inputlen: int,
                         output: ptr byte, outputlen: int,
                         seckey: PrivateKey, shmac: ptr byte = nil,
                         shlen: int = 0): AuthStatus =
  result = Success
  if eciesDecrypt(input, output, inputlen, outputlen,
                  seckey, shmac, shlen) != EciesStatus.Success:
    result = EciesError

proc decryptAuthMessage*(input: AuthMessage, output: var PlainAuthMessage,
                         seckey: PrivateKey): AuthStatus =
  result = decryptAuthMessage(unsafeAddr input[0], AuthMessageLength,
                              addr output[0], PlainAuthMessageLength,
                              seckey)

proc encryptAuthAckMessage*(input: ptr byte, inputlen: int,
                            output: ptr byte, outputlen: int,
                            pubkey: PublicKey, shmac: ptr byte = nil,
                            shlen: int = 0): AuthStatus =
  result = Success
  if eciesEncrypt(input, output, inputlen, outputlen,
                  pubkey, shmac, shlen) != EciesStatus.Success:
    result = EciesError

proc encryptAuthAckMessage*(input: PlainAuthAckMessage,
                            output: var AuthAckMessage,
                            pubkey: PublicKey): AuthStatus =
  result = encryptAuthAckMessage(unsafeAddr input[0], PlainAuthAckMessageLength,
                                 addr output[0], AuthAckMessageLength,
                                 pubkey)

proc decryptAuthAckMessage*(input: ptr byte, inputlen: int,
                            output: ptr byte, outputlen: int,
                            seckey: PrivateKey, shmac: ptr byte = nil,
                            shlen: int = 0): AuthStatus =
  result = Success
  if eciesDecrypt(input, output, inputlen, outputlen,
                  seckey, shmac, shlen) != EciesStatus.Success:
    result = EciesError

proc decryptAuthAckMessage*(input: AuthAckMessage,
                            output: var PlainAuthAckMessage,
                            seckey: PrivateKey): AuthStatus =
  result = decryptAuthAckMessage(unsafeAddr input[0], AuthAckMessageLength,
                                 addr output[0], PlainAuthAckMessageLength,
                                 seckey)

proc decodePlainAuthMessage(h: var Handshake, m: PlainAuthMessage): AuthStatus =
  var secret: SharedSecret
  var nonce: array[32, byte]
  var pubkey: PublicKey

  copyMem(addr nonce[0], unsafeAddr m[161], KeyLength)
  if recoverPublicKey(unsafeAddr m[97], sizeof(PublicKey),
                      pubkey) != EccStatus.Success:
    return(InvalidPubKey)

  if ecdhAgree(h.host.seckey, pubkey, secret) != EccStatus.Success:
    return(EcdhError)

  var xornonce = nonce
  xornonce.sxor(secret)

  if recoverSignatureKey(unsafeAddr m[0], SignatureLength, addr xornonce[0],
                         h.remoteEPubkey) != EccStatus.Success:
    return(SignatureError)

  h.initiatorNonce = nonce
  h.remoteHPubkey = pubkey
  result = Success

proc decodePlainAuthAckMessage*(h: var Handshake,
                                m: PlainAuthAckMessage): AuthStatus =
  if recoverPublicKey(m, h.remoteEPubkey, 0, 63) != EccStatus.Success:
    return(InvalidPubKey)

  h.responderNonce[0..31] = m[64..95]
  result = Success

proc getSecrets*(h: var Handshake,
                 msg: ptr byte, msglen: int,
                 ack: ptr byte, acklen: int,
                 secret: var ConnectionSecret): AuthStatus =

  var
    shsec: SharedSecret
    ctx0: keccak256
    ctx1: keccak256
    digest: array[keccak256.sizeDigest, byte]
    mac1: array[keccak256.sizeDigest, byte]
    mac2: array[keccak256.sizeDigest, byte]
    xornonce: Nonce

  # ecdhe-secret = ecdh.agree(ephemeral-privkey, remote-ephemeral-pubk)
  if ecdhAgree(h.ephemeral.seckey, h.remoteEPubkey, shsec) != EccStatus.Success:
    return(EcdhError)

  # shared-secret = keccak(ecdhe-secret || keccak(nonce || initiator-nonce))
  ctx0.init()
  ctx1.init()
  ctx1.update(addr h.responderNonce[0], uint(len(h.responderNonce)))
  ctx1.update(addr h.initiatorNonce[0], uint(len(h.initiatorNonce)))
  digest = ctx1.finish().data

  ctx1.init() # clean keccak256 context
  ctx0.update(addr shsec[0], uint(sizeof(SharedSecret)))
  ctx0.update(addr digest[0], uint(keccak256.sizeDigest))
  digest = ctx0.finish().data

  # aes-secret = keccak(ecdhe-secret || shared-secret)
  ctx0.init()
  ctx0.update(addr shsec[0], uint(sizeof(SharedSecret)))
  ctx0.update(addr digest[0], uint(keccak256.sizeDigest))
  secret.aesKey = ctx0.finish().data

  # mac-secret = keccak(ecdhe-secret || aes-secret)
  ctx0.init()
  ctx0.update(addr shsec[0], uint(sizeof(SharedSecret)))
  ctx0.update(addr secret.aesKey[0], uint(keccak256.sizeDigest))
  secret.macKey = ctx0.finish().data

  zeroMem(addr shsec[0], sizeof(SharedSecret)) # clean ecdhe-secret

  # egress-mac = keccak256(mac-secret ^ recipient-nonce || auth-sent-init)
  xornonce = secret.macKey
  xornonce.sxor(h.responderNonce)
  ctx0.init()
  ctx0.update(addr xornonce[0], uint(sizeof(Nonce)))
  ctx0.update(msg, uint(msglen))
  mac1 = ctx0.finish().data

  # ingress-mac = keccak256(mac-secret ^ initiator-nonce || auth-recvd-ack)
  xornonce = secret.macKey
  xornonce.sxor(h.initiatorNonce)
  ctx0.init()
  ctx0.update(addr xornonce[0], uint(sizeof(Nonce)))
  ctx0.update(ack, uint(acklen))
  mac2 = ctx0.finish().data

  ctx0.init() # clean keccak256 context
  zeroMem(addr xornonce[0], sizeof(Nonce)) # clean xornonce

  if Initiator in h.flags:
    secret.egressMac = mac1
    secret.ingressMac = mac2
  else:
    secret.ingressMac = mac1
    secret.egressMac = mac2

  zeroMem(addr mac1[0], keccak256.sizeDigest) # clean temporary mac1
  zeroMem(addr mac2[0], keccak256.sizeDigest) # clean temporary mac2

  result = Success

proc getSecrets*(h: var Handshake, msg: AuthMessage, ack: AuthAckMessage,
                 secret: var ConnectionSecret): AuthStatus =
  result = getSecrets(h, unsafeAddr msg[0], AuthMessageLength,
                      unsafeAddr ack[0], AuthAckMessageLength,
                      secret)

proc decodeAuthEip8Message*(h: var Handshake, msg: ptr byte,
                            msglen: int): AuthStatus =
  var
    pubkey: PublicKey
    nonce: Nonce
    size: uint16
    secret: SharedSecret
  if msglen < 2:
    return(InvalidAuth)
  bigEndian16(addr size, msg)

  if (2 + int(size)) > msglen:
    return(InvalidAuth)

  # Maximum `size` value is 65535 bytes
  var outlen = eciesDecryptedLength(int(size))
  var output = newSeq[byte](outlen)
  var input = cast[ptr UncheckedArray[byte]](msg)
  if decryptAuthMessage(addr input[2], int(size), addr output[0],
                        outlen, h.host.seckey,
                        addr input[0], 2) != Success:
    return(EciesError)

  try:
    var reader = rlpFromBytes(initBytesRange(output))
    if not reader.isList() or reader.listLen() < 4:
      return(InvalidAuth)
    if reader.listElem(0).blobLen != SignatureLength:
      return(InvalidAuth)
    if reader.listElem(1).blobLen != PublicKeyLength:
      return(InvalidAuth)
    if reader.listElem(2).blobLen != KeyLength:
      return(InvalidAuth)
    if reader.listElem(3).blobLen != 1:
      return(InvalidAuth)

    var signatureBr = reader.listElem(0).toBytes()
    var pubkeyBr = reader.listElem(1).toBytes()
    var nonceBr = reader.listElem(2).toBytes()
    var versionBr = reader.listElem(3).toBytes()

    if recoverPublicKey(addr output[pubkeyBr.ibegin], PublicKeyLength,
                        pubkey) != EccStatus.Success:
      return(InvalidPubKey)
    copyMem(addr nonce[0], addr output[nonceBr.ibegin], KeyLength)

    if ecdhAgree(h.host.seckey, pubkey, secret) != EccStatus.Success:
      return(EcdhError)

    var xornonce = nonce
    xornonce.sxor(secret)

    if recoverSignatureKey(addr output[signatureBr.ibegin], SignatureLength,
                           addr xornonce[0],
                           h.remoteEPubkey) != EccStatus.Success:
      return(SignatureError)

    h.initiatorNonce = nonce
    h.remoteHPubkey = pubkey
    h.version = output[versionBr.ibegin]
    result = Success
  except:
    return(RlpError)

proc decodeAuthAckEip8Message(h: var Handshake, msg: ptr byte,
                              msglen: int): AuthStatus =
  var size: uint16
  if msglen < 2:
    return(IncompleteError)
  bigEndian16(addr size, msg)

  if (2 + int(size)) > msglen:
    return(IncompleteError)

  # Maximum `size` value is 65535 bytes
  var outlen = eciesDecryptedLength(int(size))
  var output = newSeq[byte](outlen)
  var input = cast[ptr UncheckedArray[byte]](msg)
  if decryptAuthMessage(addr input[2], int(size), addr output[0],
                        outlen, h.host.seckey,
                        addr input[0], 2) != Success:
    return(EciesError)

  try:
    var reader = rlpFromBytes(initBytesRange(output))
    if not reader.isList() or reader.listLen() < 3:
      return(InvalidAck)
    if reader.listElem(0).blobLen != PublicKeyLength:
      return(InvalidAck)
    if reader.listElem(1).blobLen != KeyLength:
      return(InvalidAck)
    if reader.listElem(2).blobLen != 1:
      return(InvalidAck)
    var pubkeyBr = reader.listElem(0).toBytes()
    var nonceBr = reader.listElem(1).toBytes()
    var versionBr = reader.listElem(2).toBytes()

    if recoverPublicKey(addr output[pubkeyBr.ibegin], PublicKeyLength,
                        h.remoteEPubkey) != EccStatus.Success:
      return(InvalidPubKey)
    copyMem(addr h.responderNonce[0], addr output[nonceBr.ibegin], KeyLength)
    h.version = output[versionBr.ibegin]
    result = Success
  except:
    return(RlpError)

proc decodeAuthMessage*(h: var Handshake, msg: ptr byte,
                        msglen: int): AuthStatus =
  if msglen < AuthMessageLength:
    return(IncompleteError)
  elif msglen == AuthMessageLength:
    # Decoding plain authentication message
    var plain: PlainAuthMessage
    result = decryptAuthMessage(msg, msglen, addr plain[0],
                                sizeof(PlainAuthMessage), h.host.seckey)
    if result == Success:
      result = decodePlainAuthMessage(h, plain)
  else:
    # Decoding EIP-8 authentication message
    result = decodeAuthEip8Message(h, msg, msglen)
    if result == Success:
      h.flags.incl(EIP8)

proc decodeAckMessage*(h: var Handshake, msg: ptr byte,
                       msglen: int): AuthStatus =
  if msglen < AuthAckMessageLength:
    return(IncompleteError)
  elif msglen == AuthAckMessageLength:
    # Decoding plain authentication ACK message
    var plain: PlainAuthAckMessage
    result = decryptAuthAckMessage(msg, msglen, addr plain[0],
                                   PlainAuthAckMessageLength,
                                   h.host.seckey)
    if result == Success:
      result = decodePlainAuthAckMessage(h, plain)
  else:
    # Decoding EIP-8 ACK authentication message
    result = decodeAuthAckEip8Message(h, msg, msglen)

proc decodeAuthMessage*(h: var Handshake, msg: openarray[byte]): AuthStatus =
  result = decodeAuthMessage(h, unsafeAddr msg[0], len(msg))

proc decodeAckMessage*(h: var Handshake, msg: openarray[byte]): AuthStatus =
  result = decodeAckMessage(h, unsafeAddr msg[0], len(msg))

when isMainModule:
  # This was generated by `print` actual auth message generated by
  # https://github.com/ethereum/py-evm/blob/master/tests/p2p/test_auth.py
  const pyevmAuth = """
    22034ad2e7545e2b0bf02ecb1e40db478dfbbf7aeecc834aec2523eb2b7e74ee
    77ba40c70a83bfe9f2ab91f0131546dcf92c3ee8282d9907fee093017fd0302d
    0034fdb5419558137e0d44cd13d319afe5629eeccb47fd9dfe55cc6089426e46
    cc762dd8a0636e07a54b31169eba0c7a20a1ac1ef68596f1f283b5c676bae406
    4abfcce24799d09f67e392632d3ffdc12e3d6430dcb0ea19c318343ffa7aae74
    d4cd26fecb93657d1cd9e9eaf4f8be720b56dd1d39f190c4e1c6b7ec66f077bb
    1100"""

  # This data comes from https://gist.github.com/fjl/3a78780d17c755d22df2
  const data = [
    ("initiator_private_key",
     "5e173f6ac3c669587538e7727cf19b782a4f2fda07c1eaa662c593e5e85e3051"),
    ("receiver_private_key",
     "c45f950382d542169ea207959ee0220ec1491755abe405cd7498d6b16adb6df8"),
    ("initiator_ephemeral_private_key",
     "19c2185f4f40634926ebed3af09070ca9e029f2edd5fae6253074896205f5f6c"),
    ("receiver_ephemeral_private_key",
     "d25688cf0ab10afa1a0e2dba7853ed5f1e5bf1c631757ed4e103b593ff3f5620"),
    ("auth_plaintext",
     """884c36f7ae6b406637c1f61b2f57e1d2cab813d24c6559aaf843c3f48962f32f
        46662c066d39669b7b2e3ba14781477417600e7728399278b1b5d801a519aa57
        0034fdb5419558137e0d44cd13d319afe5629eeccb47fd9dfe55cc6089426e46
        cc762dd8a0636e07a54b31169eba0c7a20a1ac1ef68596f1f283b5c676bae406
        4abfcce24799d09f67e392632d3ffdc12e3d6430dcb0ea19c318343ffa7aae74
        d4cd26fecb93657d1cd9e9eaf4f8be720b56dd1d39f190c4e1c6b7ec66f077bb
        1100"""),
    ("authresp_plaintext",
     """802b052f8b066640bba94a4fc39d63815c377fced6fcb84d27f791c9921ddf3e
        9bf0108e298f490812847109cbd778fae393e80323fd643209841a3b7f110397
        f37ec61d84cea03dcc5e8385db93248584e8af4b4d1c832d8c7453c0089687a7
        00"""),
    ("auth_ciphertext",
     """04a0274c5951e32132e7f088c9bdfdc76c9d91f0dc6078e848f8e3361193dbdc
        43b94351ea3d89e4ff33ddcefbc80070498824857f499656c4f79bbd97b6c51a
        514251d69fd1785ef8764bd1d262a883f780964cce6a14ff206daf1206aa073a
        2d35ce2697ebf3514225bef186631b2fd2316a4b7bcdefec8d75a1025ba2c540
        4a34e7795e1dd4bc01c6113ece07b0df13b69d3ba654a36e35e69ff9d482d88d
        2f0228e7d96fe11dccbb465a1831c7d4ad3a026924b182fc2bdfe016a6944312
        021da5cc459713b13b86a686cf34d6fe6615020e4acf26bf0d5b7579ba813e77
        23eb95b3cef9942f01a58bd61baee7c9bdd438956b426a4ffe238e61746a8c93
        d5e10680617c82e48d706ac4953f5e1c4c4f7d013c87d34a06626f498f34576d
        c017fdd3d581e83cfd26cf125b6d2bda1f1d56"""),
    ("authresp_ciphertext",
     """049934a7b2d7f9af8fd9db941d9da281ac9381b5740e1f64f7092f3588d4f87f
        5ce55191a6653e5e80c1c5dd538169aa123e70dc6ffc5af1827e546c0e958e42
        dad355bcc1fcb9cdf2cf47ff524d2ad98cbf275e661bf4cf00960e74b5956b79
        9771334f426df007350b46049adb21a6e78ab1408d5e6ccde6fb5e69f0f4c92b
        b9c725c02f99fa72b9cdc8dd53cff089e0e73317f61cc5abf6152513cb7d833f
        09d2851603919bf0fbe44d79a09245c6e8338eb502083dc84b846f2fee1cc310
        d2cc8b1b9334728f97220bb799376233e113"""),
    ("ecdhe_shared_secret",
     "e3f407f83fc012470c26a93fdff534100f2c6f736439ce0ca90e9914f7d1c381"),
    ("initiator_nonce",
     "cd26fecb93657d1cd9e9eaf4f8be720b56dd1d39f190c4e1c6b7ec66f077bb11"),
    ("receiver_nonce",
     "f37ec61d84cea03dcc5e8385db93248584e8af4b4d1c832d8c7453c0089687a7"),
    ("aes_secret",
     "c0458fa97a5230830e05f4f20b7c755c1d4e54b1ce5cf43260bb191eef4e418d"),
    ("mac_secret",
     "48c938884d5067a1598272fcddaa4b833cd5e7d92e8228c0ecdfabbe68aef7f1"),
    ("token",
     "3f9ec2592d1554852b1f54d228f042ed0a9310ea86d038dc2b401ba8cd7fdac4"),
    ("initial_egress_MAC",
     "09771e93b1a6109e97074cbe2d2b0cf3d3878efafe68f53c41bb60c0ec49097e"),
    ("initial_ingress_MAC",
     "75823d96e23136c89666ee025fb21a432be906512b3dd4a3049e898adb433847"),
    ("initiator_hello_packet",
     """6ef23fcf1cec7312df623f9ae701e63b550cdb8517fefd8dd398fc2acd1d935e
        6e0434a2b96769078477637347b7b01924fff9ff1c06df2f804df3b0402bbb9f
        87365b3c6856b45e1e2b6470986813c3816a71bff9d69dd297a5dbd935ab578f
        6e5d7e93e4506a44f307c332d95e8a4b102585fd8ef9fc9e3e055537a5cec2e9"""),
    ("receiver_hello_packet",
     """6ef23fcf1cec7312df623f9ae701e63be36a1cdd1b19179146019984f3625d4a
        6e0434a2b96769050577657247b7b02bc6c314470eca7e3ef650b98c83e9d7dd
        4830b3f718ff562349aead2530a8d28a8484604f92e5fced2c6183f304344ab0
        e7c301a0c05559f4c25db65e36820b4b909a226171a60ac6cb7beea09376d6d8""")
  ]

  # Thies test vectors was copied from EIP8 specfication
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8.md
  const eip8data = [
    ("initiator_private_key",
     "49a7b37aa6f6645917e7b807e9d1c00d4fa71f18343b0d4122a4d2df64dd6fee"),
    ("receiver_private_key",
     "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"),
    ("initiator_ephemeral_private_key",
     "869d6ecf5211f1cc60418a13b9d870b22959d0c16f02bec714c960dd2298a32d"),
    ("receiver_ephemeral_private_key",
     "e238eb8e04fee6511ab04c6dd3c89ce097b11f25d584863ac2b6d5b35b1847e4"),
    ("initiator_nonce",
     "7e968bba13b6c50e2c4cd7f241cc0d64d1ac25c7f5952df231ac6a2bda8ee5d6"),
    ("receiver_nonce",
     "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd"),
    ("auth_ciphertext_v4",
     """048ca79ad18e4b0659fab4853fe5bc58eb83992980f4c9cc147d2aa31532efd29
        a3d3dc6a3d89eaf913150cfc777ce0ce4af2758bf4810235f6e6ceccfee1acc6b
        22c005e9e3a49d6448610a58e98744ba3ac0399e82692d67c1f58849050b3024e
        21a52c9d3b01d871ff5f210817912773e610443a9ef142e91cdba0bd77b5fdf07
        69b05671fc35f83d83e4d3b0b000c6b2a1b1bba89e0fc51bf4e460df3105c444f
        14be226458940d6061c296350937ffd5e3acaceeaaefd3c6f74be8e23e0f45163
        cc7ebd76220f0128410fd05250273156d548a414444ae2f7dea4dfca2d43c057a
        db701a715bf59f6fb66b2d1d20f2c703f851cbf5ac47396d9ca65b6260bd141ac
        4d53e2de585a73d1750780db4c9ee4cd4d225173a4592ee77e2bd94d0be3691f3
        b406f9bba9b591fc63facc016bfa8"""),
    ("auth_ciphertext_eip8",
     """01b304ab7578555167be8154d5cc456f567d5ba302662433674222360f08d5f15
        34499d3678b513b0fca474f3a514b18e75683032eb63fccb16c156dc6eb2c0b15
        93f0d84ac74f6e475f1b8d56116b849634a8c458705bf83a626ea0384d4d7341a
        ae591fae42ce6bd5c850bfe0b999a694a49bbbaf3ef6cda61110601d3b4c02ab6
        c30437257a6e0117792631a4b47c1d52fc0f8f89caadeb7d02770bf999cc147d2
        df3b62e1ffb2c9d8c125a3984865356266bca11ce7d3a688663a51d82defaa8aa
        d69da39ab6d5470e81ec5f2a7a47fb865ff7cca21516f9299a07b1bc63ba56c7a
        1a892112841ca44b6e0034dee70c9adabc15d76a54f443593fafdc3b27af80597
        03f88928e199cb122362a4b35f62386da7caad09c001edaeb5f8a06d2b26fb6cb
        93c52a9fca51853b68193916982358fe1e5369e249875bb8d0d0ec36f917bc5e1
        eafd5896d46bd61ff23f1a863a8a8dcd54c7b109b771c8e61ec9c8908c733c026
        3440e2aa067241aaa433f0bb053c7b31a838504b148f570c0ad62837129e54767
        8c5190341e4f1693956c3bf7678318e2d5b5340c9e488eefea198576344afbdf6
        6db5f51204a6961a63ce072c8926c"""),
    ("auth_ciphertext_eip8_3f",
     """01b8044c6c312173685d1edd268aa95e1d495474c6959bcdd10067ba4c9013df9
        e40ff45f5bfd6f72471f93a91b493f8e00abc4b80f682973de715d77ba3a005a2
        42eb859f9a211d93a347fa64b597bf280a6b88e26299cf263b01b8dfdb7122784
        64fd1c25840b995e84d367d743f66c0e54a586725b7bbf12acca27170ae3283c1
        073adda4b6d79f27656993aefccf16e0d0409fe07db2dc398a1b7e8ee93bcd181
        485fd332f381d6a050fba4c7641a5112ac1b0b61168d20f01b479e19adf7fdbfa
        0905f63352bfc7e23cf3357657455119d879c78d3cf8c8c06375f3f7d4861aa02
        a122467e069acaf513025ff196641f6d2810ce493f51bee9c966b15c504350535
        0392b57645385a18c78f14669cc4d960446c17571b7c5d725021babbcd786957f
        3d17089c084907bda22c2b2675b4378b114c601d858802a55345a15116bc61da4
        193996187ed70d16730e9ae6b3bb8787ebcaea1871d850997ddc08b4f4ea668fb
        f37407ac044b55be0908ecb94d4ed172ece66fd31bfdadf2b97a8bc690163ee11
        f5b575a4b44e36e2bfb2f0fce91676fd64c7773bac6a003f481fddd0bae0a1f31
        aa27504e2a533af4cef3b623f4791b2cca6d490"""),
    ("authack_ciphertext_v4",
     """049f8abcfa9c0dc65b982e98af921bc0ba6e4243169348a236abe9df5f93aa69d
        99cadddaa387662b0ff2c08e9006d5a11a278b1b3331e5aaabf0a32f01281b6f4
        ede0e09a2d5f585b26513cb794d9635a57563921c04a9090b4f14ee42be1a5461
        049af4ea7a7f49bf4c97a352d39c8d02ee4acc416388c1c66cec761d2bc1c72da
        6ba143477f049c9d2dde846c252c111b904f630ac98e51609b3b1f58168ddca65
        05b7196532e5f85b259a20c45e1979491683fee108e9660edbf38f3add489ae73
        e3dda2c71bd1497113d5c755e942d1"""),
    ("authack_ciphertext_eip8",
     """01ea0451958701280a56482929d3b0757da8f7fbe5286784beead59d95089c217
        c9b917788989470b0e330cc6e4fb383c0340ed85fab836ec9fb8a49672712aeab
        bdfd1e837c1ff4cace34311cd7f4de05d59279e3524ab26ef753a0095637ac88f
        2b499b9914b5f64e143eae548a1066e14cd2f4bd7f814c4652f11b254f8a2d019
        1e2f5546fae6055694aed14d906df79ad3b407d94692694e259191cde171ad542
        fc588fa2b7333313d82a9f887332f1dfc36cea03f831cb9a23fea05b33deb999e
        85489e645f6aab1872475d488d7bd6c7c120caf28dbfc5d6833888155ed69d34d
        bdc39c1f299be1057810f34fbe754d021bfca14dc989753d61c413d261934e1a9
        c67ee060a25eefb54e81a4d14baff922180c395d3f998d70f46f6b58306f96962
        7ae364497e73fc27f6d17ae45a413d322cb8814276be6ddd13b885b201b943213
        656cde498fa0e9ddc8e0b8f8a53824fbd82254f3e2c17e8eaea009c38b4aa0a3f
        306e8797db43c25d68e86f262e564086f59a2fc60511c42abfb3057c247a8a8fe
        4fb3ccbadde17514b7ac8000cdb6a912778426260c47f38919a91f25f4b5ffb45
        5d6aaaf150f7e5529c100ce62d6d92826a71778d809bdf60232ae21ce8a437eca
        8223f45ac37f6487452ce626f549b3b5fdee26afd2072e4bc75833c2464c80524
        6155289f4"""),
    ("authack_ciphertext_eip8_3f",
     """01f004076e58aae772bb101ab1a8e64e01ee96e64857ce82b1113817c6cdd52c0
        9d26f7b90981cd7ae835aeac72e1573b8a0225dd56d157a010846d888dac7464b
        af53f2ad4e3d584531fa203658fab03a06c9fd5e35737e417bc28c1cbf5e5dfc6
        66de7090f69c3b29754725f84f75382891c561040ea1ddc0d8f381ed1b9d0d4ad
        2a0ec021421d847820d6fa0ba66eaf58175f1b235e851c7e2124069fbc202888d
        db3ac4d56bcbd1b9b7eab59e78f2e2d400905050f4a92dec1c4bdf797b3fc9b2f
        8e84a482f3d800386186712dae00d5c386ec9387a5e9c9a1aca5a573ca91082c7
        d68421f388e79127a5177d4f8590237364fd348c9611fa39f78dcdceee3f390f0
        7991b7b47e1daa3ebcb6ccc9607811cb17ce51f1c8c2c5098dbdd28fca547b3f5
        8c01a424ac05f869f49c6a34672ea2cbbc558428aa1fe48bbfd61158b1b735a65
        d99f21e70dbc020bfdface9f724a0d1fb5895db971cc81aa7608baa0920abb0a5
        65c9c436e2fd13323428296c86385f2384e408a31e104670df0791d93e743a3a5
        194ee6b076fb6323ca593011b7348c16cf58f66b9633906ba54a2ee803187344b
        394f75dd2e663a57b956cb830dd7a908d4f39a2336a61ef9fda549180d4ccde21
        514d117b6c6fd07a9102b5efe710a32af4eeacae2cb3b1dec035b9593b48b9d3c
        a4c13d245d5f04169b0b1"""),
    ("auth2ack2_aes_secret",
     "80e8632c05fed6fc2a13b0f8d31a3cf645366239170ea067065aba8e28bac487"),
    ("auth2ack2_mac_secret",
     "2ea74ec5dae199227dff1af715362700e989d889d7a493cb0639691efb8e5f98"),
    ("auth2ack2_ingress_message", "foo"),
    ("auth2ack2_ingress_mac",
     "0c7ec6340062cc46f5e9f1e3cf86f8c8c403c5a0964f5df0ebd34a75ddc86db5")
  ]

  proc testValue(s: string): string =
    for item in data:
      if item[0] == s:
        result = item[1]
        break

  proc testE8Value(s: string): string =
    for item in eip8data:
      if item[0] == s:
        result = item[1]
        break

  block:
    var initiator: Handshake
    var receiver: Handshake
    var m0, dm0: PlainAuthMessage
    var em0: AuthMessage

    initiator = newHandshake({Initiator})
    receiver = newHandshake({Responder})
    initiator.host.seckey = getPrivateKey(testValue("initiator_private_key"))
    initiator.host.pubkey = initiator.host.seckey.getPublicKey()
    var epki = testValue("initiator_ephemeral_private_key")
    initiator.ephemeral.seckey = getPrivateKey(epki)
    initiator.ephemeral.pubkey = initiator.ephemeral.seckey.getPublicKey()
    receiver.host.seckey = getPrivateKey(testValue("receiver_private_key"))
    receiver.host.pubkey = receiver.host.seckey.getPublicKey()
    var epkr = testValue("receiver_ephemeral_private_key")
    receiver.ephemeral.seckey = getPrivateKey(epkr)
    receiver.ephemeral.pubkey = receiver.ephemeral.seckey.getPublicKey()
    var n0 = fromHex(stripSpaces(testValue("initiator_nonce")))
    initiator.initiatorNonce[0..^1] = n0[0..^1]
    var n1 = fromHex(stripSpaces(testValue("receiver_nonce")))
    receiver.responderNonce[0..^1] = n1[0..^1]

    doAssert(authMessage(initiator, receiver.host.pubkey, m0) == Success)
    var m1 = fromHex(stripSpaces(testValue("auth_plaintext")))
    var m2 = fromHex(stripSpaces(pyevmAuth))

    doAssert(m0[65..^1] == m1[65..^1])
    doAssert(m0[0..^1] == m2[0..^1])

    # Check that encrypting and decrypting the auth_init gets us the orig msg.
    doAssert(encryptAuthMessage(m0, em0, receiver.host.pubkey) == Success)
    doAssert(decryptAuthMessage(em0, dm0, receiver.host.seckey) == Success)
    doAssert(m0[0..^1] == dm0[0..^1])

    # Check that the responder correctly decodes the auth msg.
    doAssert(receiver.decodeAuthMessage(em0) == Success)

    doAssert(receiver.initiatorNonce[0..^1] == n0[0..^1])
    let remoteEPubkey0 = initiator.ephemeral.pubkey.data
    doAssert(receiver.remoteEPubkey.data[0..^1] == remoteEPubkey0[0..^1])
    let remoteHPubkey0 = initiator.host.pubkey.data
    doAssert(receiver.remoteHPubkey.data[0..^1] == remoteHPubkey0[0..^1])

    # Check that the auth_ack msg generated by the responder is what we expect.
    var k0: PlainAuthAckMessage
    var ek0: AuthAckMessage
    doAssert(receiver.authAckMessage(k0) == Success)
    var ac0 = fromHex(stripSpaces(testValue("authresp_plaintext")))
    doAssert(k0[0..^1] == ac0[0..^1])
    doAssert(receiver.initiatorNonce[0..^1] == n0[0..^1])
    doAssert(encryptAuthAckMessage(k0, ek0, receiver.remoteHPubkey) == Success)

    # Check if initiator correctly decodes the auth ack msg.
    doAssert(initiator.decodeAckMessage(ek0) == Success)
    let remoteEPubkey1 = receiver.ephemeral.pubkey.data
    doAssert(initiator.remoteEPubkey.data[0..^1] == remoteEPubkey1[0..^1])
    let remoteHPubkey1 = receiver.host.pubkey.data
    doAssert(initiator.remoteHPubkey.data[0..^1] == remoteHPubkey1[0..^1])
    doAssert(initiator.responderNonce[0..^1] == n1[0..^1])

    # Check that the secrets derived from ephemeral key agreements match
    # the expected values.
    var authm = fromHex(stripSpaces(testValue("auth_ciphertext")))
    var ackm = fromHex(stripSpaces(testValue("authresp_ciphertext")))
    var taes = fromHex(stripSpaces(testValue("aes_secret")))
    var tmac = fromHex(stripSpaces(testValue("mac_secret")))
    var temac = fromHex(stripSpaces(testValue("initial_egress_MAC")))
    var timac = fromHex(stripSpaces(testValue("initial_ingress_MAC")))

    var csecInitiator: ConnectionSecret
    var csecResponder: ConnectionSecret

    doAssert(initiator.getSecrets(addr authm[0], len(authm), addr ackm[0],
                                  len(ackm), csecInitiator) == Success)
    doAssert(receiver.getSecrets(addr authm[0], len(authm), addr ackm[0],
                                 len(ackm), csecResponder) == Success)

    doAssert(csecInitiator.aesKey == csecResponder.aesKey)
    doAssert(csecInitiator.macKey == csecResponder.macKey)
    doAssert(taes[0..^1] == csecInitiator.aesKey[0..^1])
    doAssert(tmac[0..^1] == csecInitiator.macKey[0..^1])

    doAssert(csecInitiator.egressMac[0..^1] == temac[0..^1])
    doAssert(csecInitiator.ingressMac[0..^1] == timac[0..^1])
    doAssert(csecResponder.egressMac[0..^1] == timac[0..^1])
    doAssert(csecResponder.ingressMac[0..^1] == temac[0..^1])

  block:
    proc newTestHandshake(flags: set[HandshakeFlag]): Handshake =
      result = newHandshake(flags)
      if Initiator in flags:
        result.host.seckey = getPrivateKey(testE8Value("initiator_private_key"))
        result.host.pubkey = result.host.seckey.getPublicKey()
        let esec = testE8Value("initiator_ephemeral_private_key")
        result.ephemeral.seckey = getPrivateKey(esec)
        result.ephemeral.pubkey = result.ephemeral.seckey.getPublicKey()
        let nonce = fromHex(stripSpaces(testE8Value("initiator_nonce")))
        result.initiatorNonce[0..(KeyLength - 1)] = nonce[0..(KeyLength - 1)]
      elif Responder in flags:
        result.host.seckey = getPrivateKey(testE8Value("receiver_private_key"))
        result.host.pubkey = result.host.seckey.getPublicKey()
        let esec = testE8Value("receiver_ephemeral_private_key")
        result.ephemeral.seckey = getPrivateKey(esec)
        result.ephemeral.pubkey = result.ephemeral.seckey.getPublicKey()
        let nonce = fromHex(stripSpaces(testE8Value("receiver_nonce")))
        result.responderNonce[0..(KeyLength - 1)] = nonce[0..(KeyLength - 1)]

    block: # auth/ack v4
      var initiator = newTestHandshake({Initiator})
      var receiver = newTestHandshake({Responder})

      # Check that the responder correctly decodes the auth msg.
      var m0 = fromHex(stripSpaces(testE8Value("auth_ciphertext_v4")))
      doAssert(receiver.decodeAuthMessage(m0) == Success)

      doAssert(receiver.initiatorNonce[0..^1] ==
               initiator.initiatorNonce[0..^1])
      let remoteEPubkey0 = initiator.ephemeral.pubkey.data
      doAssert(receiver.remoteEPubkey.data[0..^1] == remoteEPubkey0[0..^1])
      let remoteHPubkey0 = initiator.host.pubkey.data
      doAssert(receiver.remoteHPubkey.data[0..^1] == remoteHPubkey0[0..^1])

      # Check that the initiator correctly decodes the auth ack msg.
      var m1 = fromHex(stripSpaces(testE8Value("authack_ciphertext_v4")))
      doAssert(initiator.decodeAckMessage(m1) == Success)

      let remoteEPubkey1 = receiver.ephemeral.pubkey.data
      doAssert(initiator.remoteEPubkey.data[0..^1] == remoteEPubkey1[0..^1])
      doAssert(initiator.responderNonce[0..^1] ==
               receiver.responderNonce[0..^1])

    block: # auth/ack eip8
      var initiator = newTestHandshake({Initiator})
      var receiver = newTestHandshake({Responder})

      # Check that the responder correctly decodes the auth msg.
      var m0 = fromHex(stripSpaces(testE8Value("auth_ciphertext_eip8")))
      doAssert(receiver.decodeAuthMessage(m0) == Success)

      doAssert(receiver.initiatorNonce[0..^1] ==
               initiator.initiatorNonce[0..^1])
      let remoteEPubkey0 = initiator.ephemeral.pubkey.data
      doAssert(receiver.remoteEPubkey.data[0..^1] == remoteEPubkey0[0..^1])
      let remoteHPubkey0 = initiator.host.pubkey.data
      doAssert(receiver.remoteHPubkey.data[0..^1] == remoteHPubkey0[0..^1])

      # Check that the initiator correctly decodes the auth ack msg.
      var m1 = fromHex(stripSpaces(testE8Value("authack_ciphertext_eip8")))
      doAssert(initiator.decodeAckMessage(m1) == Success)

      let remoteEPubkey1 = receiver.ephemeral.pubkey.data
      doAssert(initiator.remoteEPubkey.data[0..^1] == remoteEPubkey1[0..^1])
      doAssert(initiator.responderNonce[0..^1] ==
               receiver.responderNonce[0..^1])

      # Check that the secrets derived from ephemeral key agreements match
      # the expected values.
      var taes = fromHex(stripSpaces(testE8Value("auth2ack2_aes_secret")))
      var tmac = fromHex(stripSpaces(testE8Value("auth2ack2_mac_secret")))

      var csecInitiator: ConnectionSecret
      var csecResponder: ConnectionSecret

      doAssert(initiator.getSecrets(addr m0[0], len(m0), addr m1[0],
                                    len(m1), csecInitiator) == Success)
      doAssert(receiver.getSecrets(addr m0[0], len(m0), addr m1[0],
                                   len(m1), csecResponder) == Success)

      doAssert(csecInitiator.aesKey == csecResponder.aesKey)
      doAssert(csecInitiator.macKey == csecResponder.macKey)
      doAssert(taes[0..^1] == csecInitiator.aesKey[0..^1])
      doAssert(tmac[0..^1] == csecInitiator.macKey[0..^1])

    block: # auth/ack eip8 with 3 additional fields
      var initiator = newTestHandshake({Initiator})
      var receiver = newTestHandshake({Responder})

      # Check that the responder correctly decodes the auth msg.
      var m0 = fromHex(stripSpaces(testE8Value("auth_ciphertext_eip8_3f")))
      doAssert(receiver.decodeAuthMessage(m0) == Success)

      doAssert(receiver.initiatorNonce[0..^1] ==
               initiator.initiatorNonce[0..^1])
      let remoteEPubkey0 = initiator.ephemeral.pubkey.data
      doAssert(receiver.remoteEPubkey.data[0..^1] == remoteEPubkey0[0..^1])
      let remoteHPubkey0 = initiator.host.pubkey.data
      doAssert(receiver.remoteHPubkey.data[0..^1] == remoteHPubkey0[0..^1])

      # Check that the initiator correctly decodes the auth ack msg.
      var m1 = fromHex(stripSpaces(testE8Value("authack_ciphertext_eip8_3f")))
      doAssert(initiator.decodeAckMessage(m1) == Success)

      let remoteEPubkey1 = receiver.ephemeral.pubkey.data
      doAssert(initiator.remoteEPubkey.data[0..^1] == remoteEPubkey1[0..^1])
      doAssert(initiator.responderNonce[0..^1] ==
               receiver.responderNonce[0..^1])