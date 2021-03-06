import
  sets, options, random, hashes,
  asyncdispatch2, chronicles, eth_common/eth_types,
  private/types, rlpx, peer_pool, rlpx_protocols/eth_protocol,
  ../eth_p2p.nim

const
  minPeersToStartSync* = 2 # Wait for consensus of at least this
                           # number of peers before syncing

type
  SyncStatus* = enum
    syncSuccess
    syncNotEnoughPeers
    syncTimeOut

  WantedBlocksState = enum
    Initial,
    Requested,
    Received,
    Persisted

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
    hasOutOfOrderBlocks: bool

proc hash*(p: Peer): Hash {.inline.} = hash(cast[pointer](p))

proc endIndex(b: WantedBlocks): BlockNumber =
  result = b.startIndex
  result += (b.numBlocks - 1).u256

proc availableWorkItem(ctx: SyncContext): int =
  var maxPendingBlock = ctx.finalizedBlock
  echo "queue len: ", ctx.workQueue.len
  result = -1
  for i in 0 .. ctx.workQueue.high:
    case ctx.workQueue[i].state
    of Initial:
      return i
    of Persisted:
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

proc persistWorkItem(ctx: SyncContext, wi: var WantedBlocks) =
  ctx.chain.persistBlocks(wi.headers, wi.bodies)
  wi.headers.setLen(0)
  wi.bodies.setLen(0)
  ctx.finalizedBlock = wi.endIndex
  wi.state = Persisted

proc persistPendingWorkItems(ctx: SyncContext) =
  var nextStartIndex = ctx.finalizedBlock + 1
  var keepRunning = true
  var hasOutOfOrderBlocks = false
  debug "Looking for out of order blocks"
  while keepRunning:
    keepRunning = false
    hasOutOfOrderBlocks = false
    for i in 0 ..< ctx.workQueue.len:
      let start = ctx.workQueue[i].startIndex
      if ctx.workQueue[i].state == Received:
        if start == nextStartIndex:
          debug "Persisting pending work item", start
          ctx.persistWorkItem(ctx.workQueue[i])
          nextStartIndex = ctx.finalizedBlock + 1
          keepRunning = true
          break
        else:
          hasOutOfOrderBlocks = true

  ctx.hasOutOfOrderBlocks = hasOutOfOrderBlocks

proc returnWorkItem(ctx: SyncContext, workItem: int) =
  let wi = addr ctx.workQueue[workItem]
  let askedBlocks = wi.numBlocks.int
  let receivedBlocks = wi.headers.len
  let start = wi.startIndex

  if askedBlocks == receivedBlocks:
    debug "Work item complete", start,
                                askedBlocks,
                                receivedBlocks
  else:
    warn "Work item complete", start,
                                askedBlocks,
                                receivedBlocks

  if wi.startIndex != ctx.finalizedBlock + 1:
    info "Blocks out of order", start, final = ctx.finalizedBlock
    ctx.hasOutOfOrderBlocks = true
  else:
    info "Persisting blocks", start
    ctx.persistWorkItem(wi[])
    if ctx.hasOutOfOrderBlocks:
      ctx.persistPendingWorkItems()

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

        if bodies.len == workItem.headers.len:
          shallowCopy(workItem.bodies, bodies)
          dataReceived = true
        else:
          warn "Bodies len != headers.len", bodies = bodies.len, headers = workItem.headers.len
    except:
      # the success case uses `continue`, so we can just fall back to the
      # failure path below. If we signal time-outs with exceptions such
      # failures will be easier to handle.
      discard

    if dataReceived:
      workItem.state = Received
      syncCtx.returnWorkItem workItemIdx
    else:
      workItem.state = Initial
      try:
        await peer.disconnect(SubprotocolReason)
      except:
        discard
      syncCtx.handleLostPeer()
      break

  debug "Fininshed otaining blocks", peer

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
  debug "start sync ", peer, trustedPeers = ctx.trustedPeers.len
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
  f.callback = proc(data: pointer) {.gcsafe.} =
    if f.failed:
      error "startSyncWithPeer failed", msg = f.readError.msg, peer

proc onPeerDisconnected(ctx: SyncContext, p: Peer) =
  debug "peer disconnected ", peer = p
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

