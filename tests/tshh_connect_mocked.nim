#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  options, unittest, asyncdispatch2, rlp, eth_keys,
  eth_p2p, eth_p2p/mock_peers, eth_p2p/rlpx_protocols/[whisper_protocol]

proc localAddress(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port, ip: parseIpAddress("127.0.0.1"))

template asyncTest(name, body: untyped) =
  test name:
    proc scenario {.async.} = body
    waitFor scenario()

asyncTest "network with 3 peers using the Whisper protocol":
  const useCompression = defined(useSnappy)
  let localKeys = newKeyPair()
  let localAddress = localAddress(30303)
  var localNode = newEthereumNode(localKeys, localAddress, 1, nil,
                                  addAllCapabilities = false,
                                  useCompression = useCompression)
  localNode.addCapability Whisper
  localNode.startListening()

  var mock1 = newMockPeer do (m: MockConf):
    m.addHandshake Whisper.status(protocolVersion: whisperVersion, powConverted: 0,
                                  bloom: @[], isLightNode: false)
    m.expect Whisper.messages

  var mock2 = newMockPeer do (m: MockConf):
    m.addHandshake Whisper.status(protocolVersion: whisperVersion,
                                  powConverted: cast[uint](0.1),
                                  bloom: @[], isLightNode: false)
    m.expect Whisper.messages

  var mock1Peer = await localNode.rlpxConnect(mock1)
  var mock2Peer = await localNode.rlpxConnect(mock2)

  check:
    mock1Peer.state(Whisper).powRequirement == 0
    mock2Peer.state(Whisper).powRequirement == 0.1
