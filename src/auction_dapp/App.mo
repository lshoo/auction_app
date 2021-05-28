import Array "mo:base/Array";
import Hash "mo:base/Hash";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Option "mo:base/Option";

import Balances "./Balances";
import Types "./Types";

actor class App(balancesAddr: Principal) = App {

    type Auction = Types.Auction;
    type AuctionId = Types.AuctionId;
    type Item = Types.Item;
    type Result = Types.Result;
    type UserId = Types.UserId;

    let balances = actor (Principal.toText(balancesAddr)) : Balances.Balances;

    let auctions = HashMap.HashMap<AuctionId, Auction>(1, Nat.equal, Hash.hash);
    var auctionCounter = 0;

    /// Query functions:

    public query func getAuctions() : async ([(AuctionId, Auction)]) {
        let entries = auctions.entries();
        Iter.toArray<(AuctionId, Auction)>(entries)
    };

    /// Update functions:

    /// Creates a new item and corresponding auction.
    /// Args:
    ///     |owner|     The UserId of the auction owner.
    ///     |name|      The item's name.
    ///     |description|   The item's description.
    ///     |url|       The url the auction can be access at.
    ///     |startingBid|  The starting price of the item
    public func startAuction(
        owner: UserId,
        name: Text,
        description: Text,
        url: Text,
        startingBid: Nat
    ) {
        let item = makeItem(name, description, url);
        let auction = makeAuction(owner, item, startingBid);
        auctions.put(auctionCounter, auction);
        auctionCounter += 1;
    };


    /// Records a new user bid for an auction.
    /// Args:
    ///   |bidder|     The UserId of the bidder.
    ///   |auctionId|  The id of the auction.
    ///   |amount|     The user's bit amount.
    /// Returns:
    ///   A Result indicating if the bid was successfully processed (see "Error" in Types.mo for possible errors).
    public func makeBid(bidder: UserId, auctionId: AuctionId, amount: Nat) : async (Result) {
        let balance = await balances.getBalance(bidder);
        if (amount > balance) return #err(#insufficientBalance);

        let auctionCheck = auctions.get(auctionId);
        switch (auctionCheck) {
            case (null) {
                #err(#auctionNotFound)
            };
            case (?auction) {
                // Distributed System module2
                if (Time.now() > auction.ttl) { return #err(#auctionExpired) };

                switch (acquireLock(bidder, auctionId, auction)) {
                    case (#err(e)) #err(e);
                    case (#ok) {
                        switch (auction.highestBidder) {
                            case (null) {
                                auctions.put(auctionId, setNewBidderAndGet(auction, amount, bidder));
                                #ok()
                            };
                            case (?prviousHighestBidder) {
                                if (amount > auction.highestBid) {
                                    let myPrincipal = Principal.fromActor(App);
                                    ignore balances.transfer(bidder, myPrincipal, amount);
                                    ignore balances.transfer(myPrincipal, prviousHighestBidder, auction.highestBid);
                                    auctions.put(auctionId, setNewBidderAndGet(auction, amount, bidder));
                                    #ok()
                                } else {
                                    #err(#belowMinimumBid) /// FIXME
                                }
                            };
                        }
                    };
                }
                
            };
        }
    };

    /// Helper method used to create a new item (used in startAuction).
    /// Args:
    ///   |name|         The item's name.
    ///   |description|  The item's description.
    ///   |url|          The URL the auction can be accesses at.
    /// Returns:
    ///   The newly created Item (see Item in Types.mo)
    func makeItem(name: Text, description: Text, url: Text) : (Item) {
        {
            name = name;
            description = description;
            url = url;
        }
    };

    /// Helper method used to create a new item (used in auctionItem).
    /// Args:
    ///   |owner|         The auction's owner.
    ///   |item|          The item object.
    ///   |startingBid|   The starting bid of the auction.
    /// Returns:
    ///   The newly created Auction (see Auction in Types.mo)
    func makeAuction(
        owner: UserId,
        item: Item,
        startingBid: Nat
    ) : (Auction) {
        {
            owner = owner;
            item = item;
            highestBid = startingBid;
            highestBidder = null;
            ttl = Time.now() + (3600 * 1000_1000_1000);
            lock = owner;
            lock_ttl = 0;
        }
    };

    /// Helper method used to set a new highest bidder in an auction and return new Action instance(used in makeBid).
    /// Args:
    ///   |auction|  The auction id.
    ///   |bidder|   The highest bidder's Principal id.
    ///   |bid|      The highest bid of the auction.
    /// Returns:
    ///   The new updated Auction (see Auction in Types.mo)
    func setNewBidderAndGet(auction: Auction, bid: Nat, bidder: Principal) : (Auction) {
        {
            owner = auction.owner;
            item = auction.item;
            highestBid = bid;
            highestBidder = ?bidder;
            ttl = auction.ttl;
            lock = auction.lock;
            lock_ttl = auction.lock_ttl;
        }
    };

    /// setNewLock() Helper method used to set a new highest bidder in an auction (used in acquireLock())
    /// Args:
    ///     |auction|   The Auction being updated
    ///     |lockAcquirer|  The id of the user acquiring the lock
    /// Returns:
    ///     The updated Auction
    func setNewLock(auction: Auction, lockAcquirer: UserId) : (Auction) {
        {
            owner = auction.owner;
            item = auction.item;
            highestBid = auction.highestBid;
            highestBidder = auction.highestBidder;
            ttl = auction.ttl;
            lock = lockAcquirer;
            lock_ttl = Time.now() + (3600 * 1000_1000);
        }
    };

    /// acquireLock() Helper a "lock" in a user's name for a particular Auction, preventing other users from
    /// bidding on the auction for a short time (used in makeBid())
    /// Args:
    ///     |id|    The UserId of the user acquiring the lock
    ///     |auctionId| The id of the auction
    ///     |auction|   The auction itself
    /// Returns:
    ///     A Result indicating if the lock was successfully acquired 
    func acquireLock(
        id: UserId,
        auctionId: AuctionId,
        auction: Auction
    ) : (Result) {
        if (id == Option.unwrap(auction.highestBidder)) {
            #err(#highestBidderNotPermitted)
        } else if (Time.now() > auction.lock_ttl) {
            auctions.put(auctionId, setNewLock(auction, id));
            #ok()
        } else {
            #err(#lockNotAcquired)
        }
    }
}