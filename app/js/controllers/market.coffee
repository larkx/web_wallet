angular.module("app").controller "MarketController", ($scope, $state, $stateParams, $modal, $location, $q, $log, $filter, Wallet, WalletAPI, Blockchain, BlockchainAPI, Growl, Utils, MarketService, Observer) ->
    $scope.showContextHelp "market"
    $scope.account_name = account_name = $stateParams.account
    return if not account_name or account_name == 'no:account'
    $scope.bid = new MarketService.TradeData
    $scope.ask = new MarketService.TradeData
    $scope.short = new MarketService.TradeData
    $scope.accounts = []
    $scope.account = account = {name: account_name, base_balance: 0.0, quantity_balance: 0.0}
    $scope.avg_price = 0
    current_market = null
    price_decimals = 4

    # tabs
    tabs_basic = []
    tabs_advanced = []
    tabs_basic.push { heading: "market.buy", route: "market.buy", active: true, class: "tab-buy" }
    tabs_basic.push { heading: "market.sell", route: "market.sell", active: false, class: "tab-sell" }
    tabs_advanced = tabs_basic.slice 0
    tabs_advanced.push { heading: "market.short", route: "market.short", active: false, class: "tab-short" }
    if $scope.advanced
        $scope.tabs = tabs_advanced
    else
        $scope.tabs = tabs_basic

    $scope.goto_tab = (route) -> $state.go route
    $scope.active_tab = (route) -> $state.is route
    $scope.$on "$stateChangeSuccess", ->
        #$scope.state_name = $state.current.name
        $scope.tabs.forEach (tab) -> tab.active = $scope.active_tab(tab.route)

    Wallet.get_account(account.name).then (acct) ->
        Wallet.set_current_account(acct)

    account_balances_observer =
        name: "account_balances_observer"
        frequency: "each_block"
        update: (data, deferred) ->
            changed = false
            promise = WalletAPI.account_balance(account_name)
            promise.then (result) =>
                #console.log "------ account_balances_observer result ------>", result
                return if !result or result.length == 0
                name_bal_pair = result[0]
                balances = name_bal_pair[1]
                angular.forEach balances, (asset_id_amt_pair) =>
                    asset_id = asset_id_amt_pair[0]
                    asset_record = Blockchain.asset_records[asset_id]
                    symbol = asset_record.symbol
                    if data[symbol] != undefined
                        value = asset_id_amt_pair[1]
                        if data[symbol] != value
                            changed = true
                            data[symbol] = value
            promise.finally -> deferred.resolve(changed)


    market_data_observer =
        name: "market_data_observer"
        frequency: "each_block"
        data: {context: MarketService, account_name: account.name}
        update: MarketService.pull_market_data

    market_status_observer =
        name: "market_status_observer"
        frequency: "each_block"
        data: {context: MarketService}
        update: MarketService.pull_market_status


    market_name = $stateParams.name
    promise = MarketService.init(market_name)
    promise.then (market) ->
        $scope.market = current_market = market
        $scope.actual_market = market.get_actual_market()
        $scope.market_inverted_url = MarketService.inverted_url
        $scope.bids = MarketService.bids
        $scope.asks = MarketService.asks
        $scope.shorts = MarketService.shorts
        $scope.covers = MarketService.covers
        $scope.trades = MarketService.trades
        $scope.my_trades = MarketService.my_trades
        $scope.orders = MarketService.orders
        price_decimals = if market.price_precision > 9 then (market.price_precision+"").length - 2 else market.price_precision - 2
        Observer.registerObserver(market_data_observer)
        Observer.registerObserver(market_status_observer)
        balances = {}
        balances[market.asset_base_symbol] = 0.0
        balances[market.asset_quantity_symbol] = 0.0
        account_balances_observer.data = balances
        account_balances_observer.notify = (data) ->
            account.base_balance = data[market.asset_base_symbol] / market.base_precision
            account.quantity_balance = data[market.asset_quantity_symbol] / market.quantity_precision
            account.short_balance = if market.inverted then account.base_balance else account.quantity_balance
        Observer.registerObserver(account_balances_observer)
    promise.catch (error) -> Growl.error("", error)
    $scope.showLoadingIndicator(promise)

    Wallet.refresh_accounts().then ->
        $scope.accounts.splice(0, $scope.accounts.length)
        for k,a of Wallet.accounts
            $scope.accounts.push a if a.is_my_account

    $scope.excludeOutOfRange = (item) -> not item.out_of_range

    $scope.$on "$destroy", ->
        $scope.showContextHelp false
        MarketService.orders = []
        MarketService.my_trades = []
        Observer.unregisterObserver(market_data_observer)
        Observer.unregisterObserver(market_status_observer)
        Observer.unregisterObserver(account_balances_observer)

    $scope.flip_market = ->
        console.log "flip market"
        $state.go('^.buy', {name: $scope.market.inverted_url})

    $scope.flip_advanced = ->
        $scope.advanced = ! $scope.advanced
        if $scope.advanced
            $scope.tabs = tabs_advanced
        else
            $scope.tabs = tabs_basic

    $scope.cancel_order = (id) ->
        res = MarketService.cancel_order(id)
        return unless res
        #res.then -> Growl.notice "", "Your order was canceled."

    $scope.submit_bid = ->
        form = @buy_form
        $scope.clear_form_errors(form)
        bid = $scope.bid
        bid.cost = bid.quantity * bid.price
        if bid.cost > $scope.account.base_balance
            form.bid_quantity.$error.message = 'market.tip.insufficient_balances'
            return
        bid.type = "bid_order"
        bid.display_type = "Bid"
        $scope.account.base_balance -= bid.cost
        if $scope.market.lowest_ask > 0
            price_diff = 100.0 * bid.price / $scope.market.lowest_ask - 100
            if price_diff > 5
                bid.warning = "market.tip.bid_price_too_high"
                bid.price_diff = Utils.formatDecimal(price_diff, 1)
        MarketService.add_unconfirmed_order(bid)
        #$scope.bid = new MarketService.TradeData

    $scope.submit_ask = ->
        form = @sell_form
        $scope.clear_form_errors(form)
        ask = $scope.ask
        ask.cost = ask.quantity * ask.price
        if ask.quantity > $scope.account.quantity_balance
            form.ask_quantity.$error.message = 'market.tip.insufficient_balances'
            return
        ask.type = "ask_order"
        ask.display_type = "Ask"
        if $scope.market.highest_bid > 0
            price_diff = 100 - 100.0 * ask.price / $scope.market.highest_bid
            if price_diff > 5
                ask.warning = "market.tip.ask_price_too_low"
                ask.price_diff = Utils.formatDecimal(price_diff, 1)
        MarketService.add_unconfirmed_order(ask)
        #$scope.ask = new MarketService.TradeData

    $scope.submit_short = ->
        form = @short_form
        $scope.clear_form_errors(form)
        short = angular.copy($scope.short)
        short.price = $scope.market.shorts_price
        console.log "------ submit_short ------>", $scope.market.inverted, short
        if $scope.market.inverted
            short.cost = short.quantity * short.collateral_ratio
        else
            short.cost = short.quantity
            short.quantity = short.cost * short.collateral_ratio

        short.type = "short_order"
        short.display_type = "Short"

        MarketService.add_unconfirmed_order(short)
        #$scope.short = new MarketService.TradeData

    $scope.confirm_order = (id) ->
        MarketService.confirm_order(id, $scope.account).then (order) ->
            if order.type == "bid_order" or order.type == "ask_order"
                $scope.account.base_balance -= order.cost
            else if order.type == "ask_order"
                $scope.account.quantity_balance -= order.cost
            #Growl.notice "", "Your order was successfully placed."
        , (error) ->
            Growl.error "", "Order failed: " + error.data.error.message

    $scope.use_trade_data = (data) ->
        order = switch $state.current.name
            when "market.sell" then $scope.ask
            when "market.short" then $scope.short
            else $scope.bid
        order.quantity = Utils.formatDecimal(data.quantity, $scope.market.quantity_precision, true) if data.quantity
        order.collateral_ratio = Utils.formatDecimal(data.collateral_ratio, $scope.market.quantity_precision, true) if data.collateral_ratio
        if data.price
            makeweight = switch $state.current.name
                when "market.sell" then -.0001
                when "market.short" then -.0001
                else .0001
            price = data.price + data.price * makeweight
            order.price = Utils.formatDecimal(price, $scope.market.price_precision, true)

    $scope.submit_test = ->
        form = @buy_form
        $scope.clear_form_errors(form)
        form.bid_quantity.$error.message = "some field error, please fix me"
        form.bid_price.$error.message = "another field error, please fix me"
        form.$error.message = "some error, please fix me"

    $scope.cover_order = (order) ->
        $modal.open
            templateUrl: "market/cover_order_confirmation.html"
            controller: ["$scope", "$modalInstance", (scope, modalInstance) ->
                scope.market = current_market.actual_market or current_market
                original_order = order
                #console.log order
                if !current_market.inverted
                    order = order.invert()
                scope.v = {quantity: order.quantity, total: order.quantity}
                scope.cancel = ->
                    modalInstance.dismiss "cancel"
                scope.submit = ->
                    form = @cover_form
                    original_order.status = "pending"
                    MarketService.cover_order(order, scope.v.quantity, account)
                    .then ->
                        original_order.status = "pending"
                        modalInstance.dismiss "ok"
                    , (error) ->
                        form.quantity.$error.message = error.data.error.message
            ]
