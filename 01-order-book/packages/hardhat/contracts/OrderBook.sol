// Kerry Lynn Whyte - ECO5037W Assignment 2 Part 1
// 2026-05-21
// Simple order book implementation for trading between two ERC20 tokens (tokenA and tokenB) using a decentralised exchange appproach.
// all tokens are minted at once, uses internal balance for spenders/receivers
// need to ensure sender has enough balance before trading and both sender/receiver balances updated after settlement
// allowances - allows another address to spend tokens on its behalf - owner calls approve(spender, amount), and the spender later uses transferFrom(owner, recipient, amount) up to that approved limit
pragma solidity ^0.8.20; // SPDX-License-Identifier

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract OrderBook {
    using SafeERC20 for IERC20;

    IERC20 public tokenA; // base token 
    IERC20 public tokenB; // quote token 

    enum OrderType { Buy, Sell } // order can only be of buy or sell type (Buy = 0, Sell = 1)
    enum OrderStatus { Open, Closed } // order status can be open/closed (Open = 0, Closed = 1

    // Order structure to represent each order in the order book
    struct Order {
        address trader;
        OrderType orderType;
        uint256 amount;
        uint256 price;
        uint256 filled;
        OrderStatus status;
    }
    // array to store orders in order book - initially empty
    Order[] public orders;

    // Events for order placement, matching, fill updates, and cancellation
    event OrderPlaced(uint256 orderId, address trader, uint8 orderType, address sellToken, address buyToken, uint256 amount, uint256 price); // Emit event with details of the placed order, including token addresses for clarity
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId, uint256 amount); // Emit event with details of the matched orders and fill amount
    event OrderFilled(uint256 orderId, uint256 fillAmount, uint256 totalFilled); // Emit event when an order is partially or fully filled, tracking cumulative fill progress
    event OrderCanceled(uint256 orderId); // Emit event with details of the canceled order

    // Custom errors for better error handling and gas efficiency
    error InvalidAmount(); // error when order amount is zero
    error InvalidPrice(); //error when order amount or price is zero
    error PriceMismatch(); // error when bid price is less than asking price
    error UnauthorizedCancellation(); // error when someone tries to cancel order they didn't place

    /// @notice Initialises the order book with the two tokens to be traded.
    /// @param _tokenA  base token (tokenA) address
    /// @param _tokenB  quote token (tokenB) address 
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }
    /// @notice Places a buy order for tokenA, escrowing the required tokenB upfront.
    /// @param amount Number of base tokens (tokenA) the buyer wants to purchase.
    /// @param price  Price per base token denominated in quote tokens (tokenB).
    /// @return orderId The index of the newly created order in the orders array.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount(); // amount (number of tokens) must be > 0
        if (price == 0) revert InvalidPrice();  // price must be > 0

        orderId = orders.length; // index of new order (at end of array)
        // Create new buy order and add to order book - initialise filled to 0 and status as Open
        orders.push(Order({
            trader: msg.sender,
            orderType: OrderType.Buy,
            amount: amount,
            price: price,
            filled: 0, //
            status: OrderStatus.Open // order is open until fully filled or cancelled
        }));

        // Escrow tokenB (quote token) from buyer upfront based on total cost in terms of tokenB(amount * price)
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price); 
        // Emit event with details of the placed order (including token addresses)
        emit OrderPlaced(orderId, msg.sender, 0, address(tokenB), address(tokenA), amount, price); 
    }

    /// @notice Places a sell order for tokenA, escrowing the base tokens upfront.
    /// @param amount Number of base tokens (tokenA) the seller wants to sell.
    /// @param price  Minimum price per base token the seller will accept, in tokenB.
    /// @return orderId The index of the newly created order in the orders array.
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Create new sell order and add to order book
        orderId = orders.length;
        orders.push(Order({
            trader: msg.sender,
            orderType: OrderType.Sell,
            amount: amount,
            price: price,
            filled: 0,
            status: OrderStatus.Open
        }));

        // Escrow tokenA (base token) from seller upfront
        tokenA.safeTransferFrom(msg.sender, address(this), amount); 
        // Emit event with details of the placed order, including token addresses for clarity
        emit OrderPlaced(orderId, msg.sender, 1, address(tokenA), address(tokenB), amount, price);
    }

    /// @notice Matches a buy order with a sell order, transferring tokens to each trader.
    ///         Fills up to the smaller of the two orders' remaining amounts (partial fills supported).
    /// @param buyOrderId  Index of the buy order in the orders array.
    /// @param sellOrderId Index of the sell order in the orders array.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId]; // Load buy order from storage
        Order storage sellOrder = orders[sellOrderId]; // Load sell order from storage

        // if buy order (bid) price is less than sell order (asking) price - orders cannot be matched 
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // otherwise orders can be matched 
        uint256 buyRemaining = buyOrder.amount - buyOrder.filled; // Calculate remaining amount for buy order
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled; // Calculate remaining amount for sell order
        uint256 fillAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining; // Determine fill amount based on smaller remaining amount

        buyOrder.filled += fillAmount; // Update filled amount for buy order
        sellOrder.filled += fillAmount; // Update filled amount for sell order

        if (buyOrder.filled == buyOrder.amount) buyOrder.status = OrderStatus.Closed; // when filled amount = total buyer amount, close the buy order
        if (sellOrder.filled == sellOrder.amount) sellOrder.status = OrderStatus.Closed; // when filled amount = total seller amount, close the sell order

        tokenA.safeTransfer(buyOrder.trader, fillAmount); // Transfer base tokens from order book to buyer
        tokenB.safeTransfer(sellOrder.trader, fillAmount * buyOrder.price); // Transfer quote tokens from order book to seller based on buy order price (not sell order price, to ensure price priority for buyer)

        // Emit fill update for each order so listeners can track partial fill progress
        emit OrderFilled(buyOrderId, fillAmount, buyOrder.filled);
        emit OrderFilled(sellOrderId, fillAmount, sellOrder.filled);
        emit OrderMatched(buyOrderId, sellOrderId, fillAmount); // Emit event with details of the matched orders and fill amount
    }

    /// @notice Cancels an open order and refunds the escrowed tokens to the trader.
    ///         Only the trader who placed the order may cancel it.
    /// @param orderId Index of the order to cancel in the orders array.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId]; // Load order from storage
        // only trader who placed order can cancel, otherwise revert with error
        if (order.trader != msg.sender) revert UnauthorizedCancellation();

        uint256 remainingAmount = order.amount - order.filled; // Calculate remaining amount that has not been filled yet
        order.status = OrderStatus.Closed; // Mark order as closed to prevent further matching

        // Refund remaining tokens to trader based on order type
        // If it's a buy order, refund the remaining quote tokens (tokenB) to the buyer. If it's a sell order, refund the remaining base tokens (tokenA) to the seller.
        if (order.orderType == OrderType.Buy) {
            tokenB.safeTransfer(order.trader, remainingAmount * order.price);
        } else {
            tokenA.safeTransfer(order.trader, remainingAmount);
        }

        emit OrderCanceled(orderId); // Emit event with details of the canceled order
    }
    /// @notice Returns the unfilled token amount remaining for a given order.
    /// @param orderId Index of the order in the orders array.
    /// @return The number of base tokens still to be filled.
    function remaining(uint256 orderId) external view returns (uint256) {
        uint256 balance_rem = orders[orderId].amount - orders[orderId].filled;
        return balance_rem; // remaining = total order amount-filled amount
    }
    /// @notice Checks whether an order is still open and available for matching or cancellation.
    /// @param orderId Index of the order in the orders array.
    /// @return True if the order status is Open, false if it is Closed.
    function isOpen(uint256 orderId) external view returns (bool) {
        OrderStatus open_status = orders[orderId].status;
        if (open_status == OrderStatus.Open) {
            return true; // order is open
        } else {
            return false; // order is closed
        }
    }
}
