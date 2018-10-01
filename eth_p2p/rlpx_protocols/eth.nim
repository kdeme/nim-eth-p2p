#
#                 Ethereum P2P
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
#

## This module implements the Ethereum Wire Protocol:
## https://github.com/ethereum/wiki/wiki/Ethereum-Wire-Protocol

import
  random, algorithm, hashes,
  asyncdispatch2, rlp, stint, eth_common, chronicles,
  ../../eth_p2p

type
  NewBlockHashesAnnounce* = object
    hash: KeccakHash
    number: uint

  NewBlockAnnounce* = object
    header: BlockHeader
    body {.rlpInline.}: BlockBody

  NetworkState = object
    syncing: bool

  PeerState = object
    initialized: bool
    bestBlockHash: KeccakHash
    bestDifficulty: DifficultyInt

const
  maxStateFetch = 384
  maxBodiesFetch = 128
  maxReceiptsFetch = 256
  maxHeadersFetch = 192
  protocolVersion = 63
  minPeersToStartSync = 2 # Wait for consensus of at least this number of peers before syncing

rlpxProtocol eth, protocolVersion:
  useRequestIds = false

  type State = PeerState

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      chain = network.chain
      bestBlock = chain.getBestBlockHeader

    await peer.status(protocolVersion,
                      network.networkId,
                      bestBlock.difficulty,
                      bestBlock.blockHash,
                      chain.genesisHash)

    let m = await peer.waitSingleMsg(eth.status)
    if m.networkId == network.networkId and m.genesisHash == chain.genesisHash:
      debug "Suitable peer", peer
    else:
      raise newException(UselessPeerError, "Eth handshake params mismatch")
    peer.state.initialized = true
    peer.state.bestDifficulty = m.totalDifficulty
    peer.state.bestBlockHash = m.bestHash

  proc status(peer: Peer,
              protocolVersion: uint,
              networkId: uint,
              totalDifficulty: DifficultyInt,
              bestHash: KeccakHash,
              genesisHash: KeccakHash) =
    # verify that the peer is on the same chain:
    if peer.network.networkId != networkId or
       peer.network.chain.genesisHash != genesisHash:
      # TODO: Is there a more specific reason here?
      await peer.disconnect(SubprotocolReason)
      return

    peer.state.bestBlockHash = bestHash
    peer.state.bestDifficulty = totalDifficulty

  proc newBlockHashes(peer: Peer, hashes: openarray[NewBlockHashesAnnounce]) =
    discard

  proc transactions(peer: Peer, transactions: openarray[Transaction]) =
    discard

  requestResponse:
    proc getBlockHeaders(peer: Peer, request: BlocksRequest) =
      if request.maxResults > uint64(maxHeadersFetch):
        await peer.disconnect(BreachOfProtocol)
        return

      var headers = newSeqOfCap[BlockHeader](request.maxResults)
      let chain = peer.network.chain
      var foundBlock: BlockHeader

      if chain.getBlockHeader(request.startBlock, foundBlock):
        headers.add foundBlock

        while uint64(headers.len) < request.maxResults:
          if not chain.getSuccessorHeader(foundBlock, foundBlock):
            break
          headers.add foundBlock

      await peer.blockHeaders(headers)

    proc blockHeaders(p: Peer, headers: openarray[BlockHeader])

  requestResponse:
    proc getBlockBodies(peer: Peer, hashes: openarray[KeccakHash]) =
      if hashes.len > maxBodiesFetch:
        await peer.disconnect(BreachOfProtocol)
        return

      var chain = peer.network.chain

      var blockBodies = newSeqOfCap[BlockBody](hashes.len)
      for hash in hashes:
        let blockBody = chain.getBlockBody(hash)
        if not blockBody.isNil:
          # TODO: should there be an else clause here.
          # Is the peer responsible of figuring out that
          # some blocks were not found?
          blockBodies.add deref(blockBody)

      await peer.blockBodies(blockBodies)

    proc blockBodies(peer: Peer, blocks: openarray[BlockBody])

  proc newBlock(peer: Peer, bh: NewBlockAnnounce, totalDifficulty: DifficultyInt) =
    discard

  nextID 13

  requestResponse:
    proc getNodeData(peer: Peer, hashes: openarray[KeccakHash]) =
      await peer.nodeData([])

    proc nodeData(peer: Peer, data: openarray[Blob]) =
      discard

  requestResponse:
    proc getReceipts(peer: Peer, hashes: openarray[KeccakHash]) =
      await peer.receipts([])

    proc receipts(peer: Peer, receipts: openarray[Receipt]) =
      discard

proc hash*(p: Peer): Hash {.inline.} = hash(cast[pointer](p))

type
  SyncStatus* = enum
    syncSuccess
    syncNotEnoughPeers
    syncTimeOut

  WantedBlocksState = enum
    Initial,
    Requested,
    Received

  WantedBlocks = object
    startIndex: BlockNumber
    numBlocks: uint
    state: WantedBlocksState
    headers: seq[BlockHeader]
    bodies: seq[BlockBody]

  SyncContext = ref object
    workQueue: seq[WantedBlocks]
    endBlockNumber: BlockNumber
    finalizedBlock: BlockNumber # Block which was downloaded and verified
    chain: AbstractChainDB
    peerPool: PeerPool
    trustedPeers: HashSet[Peer]

proc endIndex(b: WantedBlocks): BlockNumber =
  result = b.startIndex
  result += (b.numBlocks - 1).u256

proc availableWorkItem(ctx: SyncContext): int =
  var maxPendingBlock = ctx.finalizedBlock
  result = -1
  for i in 0 .. ctx.workQueue.high:
    case ctx.workQueue[i].state
    of Initial:
      return i
    of Received:
      result = i
    else:
      discard

    let eb = ctx.workQueue[i].endIndex
    if eb > maxPendingBlock: maxPendingBlock = eb

  let nextRequestedBlock = maxPendingBlock + 1
  if nextRequestedBlock >= ctx.endBlockNumber:
    return -1

  if result == -1:
    result = ctx.workQueue.len
    ctx.workQueue.setLen(result + 1)

  var numBlocks = (ctx.endBlockNumber - nextRequestedBlock).toInt
  if numBlocks > maxHeadersFetch:
    numBlocks = maxHeadersFetch
  ctx.workQueue[result] = WantedBlocks(startIndex: nextRequestedBlock, numBlocks: numBlocks.uint, state: Initial)

proc returnWorkItem(ctx: SyncContext, workItem: int) =
  let wi = addr ctx.workQueue[workItem]
  let askedBlocks = wi.numBlocks.int
  let receivedBlocks = wi.headers.len

  if askedBlocks == receivedBlocks:
    debug "Work item complete", startBlock = wi.startIndex,
                                askedBlocks,
                                receivedBlocks
  else:
    warn "Work item complete", startBlock = wi.startIndex,
                                askedBlocks,
                                receivedBlocks

  ctx.chain.persistBlocks(wi.headers, wi.bodies)
  wi.headers.setLen(0)
  wi.bodies.setLen(0)

proc newSyncContext(chain: AbstractChainDB, peerPool: PeerPool): SyncContext =
  new result
  result.chain = chain
  result.peerPool = peerPool
  result.trustedPeers = initSet[Peer]()
  result.finalizedBlock = chain.getBestBlockHeader().blockNumber

proc handleLostPeer(ctx: SyncContext) =
  # TODO: ask the PeerPool for new connections and then call
  # `obtainBlocksFromPeer`
  discard

proc getBestBlockNumber(p: Peer): Future[BlockNumber] {.async.} =
  let request = BlocksRequest(
    startBlock: HashOrNum(isHash: true,
                          hash: p.state(eth).bestBlockHash),
    maxResults: 1,
    skip: 0,
    reverse: true)

  let latestBlock = await p.getBlockHeaders(request)

  if latestBlock.isSome and latestBlock.get.headers.len > 0:
    result = latestBlock.get.headers[0].blockNumber

proc obtainBlocksFromPeer(syncCtx: SyncContext, peer: Peer) {.async.} =
  # Update our best block number
  let bestBlockNumber = await peer.getBestBlockNumber()
  if bestBlockNumber > syncCtx.endBlockNumber:
    info "New sync end block number", number = bestBlockNumber
    syncCtx.endBlockNumber = bestBlockNumber

  while (let workItemIdx = syncCtx.availableWorkItem(); workItemIdx != -1):
    template workItem: auto = syncCtx.workQueue[workItemIdx]
    workItem.state = Requested
    debug "Requesting block headers", start = workItem.startIndex, count = workItem.numBlocks, peer
    let request = BlocksRequest(
      startBlock: HashOrNum(isHash: false,
                            number: workItem.startIndex),
      maxResults: workItem.numBlocks,
      skip: 0,
      reverse: false)

    var dataReceived = false
    try:
      let results = await peer.getBlockHeaders(request)
      if results.isSome:
        workItem.state = Received
        shallowCopy(workItem.headers, results.get.headers)

        var bodies = newSeq[BlockBody]()
        var hashes = newSeq[KeccakHash]()
        for i in workItem.headers:
          hashes.add(blockHash(i))
          if hashes.len == maxBodiesFetch:
            let b = await peer.getBlockBodies(hashes)
            hashes.setLen(0)
            bodies.add(b.get.blocks)

        if hashes.len != 0:
          let b = await peer.getBlockBodies(hashes)
          bodies.add(b.get.blocks)

        shallowCopy(workItem.bodies, bodies)
        dataReceived = true
    except:
      # the success case uses `continue`, so we can just fall back to the
      # failure path below. If we signal time-outs with exceptions such
      # failures will be easier to handle.
      discard

    if dataReceived:
      syncCtx.returnWorkItem workItemIdx
    else:
      try:
        await peer.disconnect(SubprotocolReason)
      except:
        discard
      syncCtx.handleLostPeer()
      break

  debug "Nothing to sync"

proc peersAgreeOnChain(a, b: Peer): Future[bool] {.async.} =
  # Returns true if one of the peers acknowledges existense of the best block
  # of another peer.
  var
    a = a
    b = b

  if a.state(eth).bestDifficulty < b.state(eth).bestDifficulty:
    swap(a, b)

  let request = BlocksRequest(
    startBlock: HashOrNum(isHash: true,
                          hash: b.state(eth).bestBlockHash),
    maxResults: 1,
    skip: 0,
    reverse: true)

  let latestBlock = await a.getBlockHeaders(request)
  result = latestBlock.isSome and latestBlock.get.headers.len > 0

proc randomTrustedPeer(ctx: SyncContext): Peer =
  var k = rand(ctx.trustedPeers.len - 1)
  var i = 0
  for p in ctx.trustedPeers:
    result = p
    if i == k: return
    inc i

proc startSyncWithPeer(ctx: SyncContext, peer: Peer) {.async.} =
  if ctx.trustedPeers.len >= minPeersToStartSync:
    # We have enough trusted peers. Validate new peer against trusted
    if await peersAgreeOnChain(peer, ctx.randomTrustedPeer()):
      ctx.trustedPeers.incl(peer)
      asyncCheck ctx.obtainBlocksFromPeer(peer)
  elif ctx.trustedPeers.len == 0:
    # Assume the peer is trusted, but don't start sync until we reevaluate
    # it with more peers
    debug "Assume trusted peer", peer
    ctx.trustedPeers.incl(peer)
  else:
    # At this point we have some "trusted" candidates, but they are not
    # "trusted" enough. We evaluate `peer` against all other candidates.
    # If one of the candidates disagrees, we swap it for `peer`. If all
    # candidates agree, we add `peer` to trusted set. The peers in the set
    # will become "fully trusted" (and sync will start) when the set is big
    # enough
    var
      agreeScore = 0
      disagreedPeer: Peer

    for tp in ctx.trustedPeers:
      if await peersAgreeOnChain(peer, tp):
        inc agreeScore
      else:
        disagreedPeer = tp

    let disagreeScore = ctx.trustedPeers.len - agreeScore

    if agreeScore == ctx.trustedPeers.len:
      ctx.trustedPeers.incl(peer) # The best possible outsome
    elif disagreeScore == 1:
      info "Peer is no more trusted for sync", peer
      ctx.trustedPeers.excl(disagreedPeer)
      ctx.trustedPeers.incl(peer)
    else:
      info "Peer not trusted for sync", peer

    if ctx.trustedPeers.len == minPeersToStartSync:
      for p in ctx.trustedPeers:
        asyncCheck ctx.obtainBlocksFromPeer(p)


proc onPeerConnected(ctx: SyncContext, peer: Peer) =
  debug "New candidate for sync", peer
  discard
  let f = ctx.startSyncWithPeer(peer)
  f.callback = proc(data: pointer) =
    if f.failed:
      error "startSyncWithPeer failed", msg = f.readError.msg, peer

proc onPeerDisconnected(ctx: SyncContext, p: Peer) =
  echo "onPeerDisconnected"
  ctx.trustedPeers.excl(p)

proc startSync(ctx: SyncContext) =
  var po: PeerObserver
  po.onPeerConnected = proc(p: Peer) =
    ctx.onPeerConnected(p)

  po.onPeerDisconnected = proc(p: Peer) =
    ctx.onPeerDisconnected(p)

  ctx.peerPool.addObserver(ctx, po)

proc findBestPeer(node: EthereumNode): (Peer, DifficultyInt) =
  var
    bestBlockDifficulty: DifficultyInt = 0.stuint(256)
    bestPeer: Peer = nil

  for peer in node.peers(eth):
    let peerEthState = peer.state(eth)
    if peerEthState.initialized:
      if peerEthState.bestDifficulty > bestBlockDifficulty:
        bestBlockDifficulty = peerEthState.bestDifficulty
        bestPeer = peer

  result = (bestPeer, bestBlockDifficulty)

proc fastBlockchainSync*(node: EthereumNode): Future[SyncStatus] {.async.} =
  ## Code for the fast blockchain sync procedure:
  ## https://github.com/ethereum/wiki/wiki/Parallel-Block-Downloads
  ## https://github.com/ethereum/go-ethereum/pull/1889
  # TODO: This needs a better interface. Consider removing this function and
  # exposing SyncCtx
  var syncCtx = newSyncContext(node.chain, node.peerPool)
  syncCtx.startSync()

