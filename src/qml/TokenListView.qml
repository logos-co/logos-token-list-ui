import QtQuick 2.15
import QtQuick.Layouts 1.15
import Logos.Controls
import Logos.Theme

// Token Lists — the token metadata every Logos wallet on this device shares.
//
// Two things NOT to do in this directory, both of which break at runtime rather than at build
// time: do not ship a src/qml/qmldir (the builder generates one carrying this module's private
// URI), and do not create a src/qml/Logos/ directory (the host reserves that prefix).
//
// Rendering rule: every item showing a string this view did not author sets
// `textFormat: Text.PlainText`. LogosText is a bare Text with no textFormat, i.e. Qt's AutoText
// HTML autodetection — and 6 tokens in the shipped list already carry `&` in their name.
// `logoURI` is never rendered: the backend drops it, and the sandbox refuses remote images.
Item {
    id: root
    objectName: "tokenListRoot"
    anchors.fill: parent

    // Paint the surface. Without this the QQuickWidget's white clear colour shows through and
    // LogosText's default colour renders white-on-white.
    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    readonly property var backend: logos.module("token_list_ui")

    // Must be a writable property fed by the signal, NOT a binding: a binding containing a
    // function call evaluates once at creation, before ui-host has finished handing over.
    property bool ready: false

    // Refusals this view authored itself, kept apart from the backend's lastError.
    property string formError: ""

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "token_list_ui") root.ready = isReady && root.backend !== null
        }

        // The lists and custom tokens are DEVICE-WIDE, so a wallet reports what it is using
        // and sends the user here to change it. Being brought here IS the request, so answer
        // at once; `handoff: true` leaves them here rather than bouncing them back.
        function onIntentRequested(requestId, intent, params, requesterName) {
            if (intent !== "evm.token_lists.configure") return
            logos.respond(requestId, true, ({}), "")
        }
    }

    function j(text, fallback) {
        try { return JSON.parse(text && text.length ? text : fallback) }
        catch (e) { return JSON.parse(fallback) }
    }

    readonly property var status: ready ? j(backend.statusJson, "{}") : ({})
    // Not `state`: Item already owns that name.
    readonly property string configState: status.state !== undefined ? status.state : "unready"
    readonly property string configSource: status.source !== undefined ? status.source : "none"
    readonly property var config: status.config !== undefined ? status.config : ({})
    readonly property var counts: status.counts !== undefined ? status.counts : ({})

    readonly property var chains: ready ? j(backend.chainsJson, "[]") : []
    readonly property int selectedChainId: ready ? backend.selectedChainId : 0
    readonly property var page: ready ? j(backend.pageJson, "{}") : ({})
    readonly property var sources: ready ? j(backend.sourcesJson, "[]") : []
    readonly property var lastFetch: ready ? j(backend.refreshJson, "{}") : ({})

    readonly property var listUrls: config.listUrls !== undefined ? config.listUrls : []
    readonly property int pageTotal: page.total !== undefined ? page.total : 0
    readonly property int pageLimit: page.limit !== undefined ? page.limit : 25
    readonly property int pageOffset: page.offset !== undefined ? page.offset : 0

    function chainLabel(c) {
        return (c.name !== undefined ? c.name : "Chain " + c.chainId) + " · " + c.count + " tokens"
    }
    readonly property int chainIndex: {
        for (var i = 0; i < chains.length; ++i)
            if (chains[i].chainId === selectedChainId) return i
        return 0
    }

    function stateText(s) {
        if (s === "unready") return "Starting"
        if (s === "unconfigured") return "Not configured"
        return root.configSource === "external" ? "Configured by you" : "Built-in defaults"
    }
    function stateColor(s) {
        if (s === "unready") return Theme.palette.textTertiary
        if (s === "unconfigured") return Theme.palette.warning
        return Theme.palette.success
    }

    // The table reads its rows from a ListModel, not from the parsed array: LogosTable's cell
    // delegates address a row as `rowItem[role]`, which needs model roles.
    ListModel { id: pageRows }
    function syncRows() {
        pageRows.clear()
        var rows = page.rows !== undefined ? page.rows : []
        for (var i = 0; i < rows.length; ++i) pageRows.append(rows[i])
    }
    onPageChanged: syncRows()

    // Debounced so a five-character query does not re-page five times.
    Timer {
        id: filterDebounce
        interval: 250
        onTriggered: if (root.ready) root.backend.setFilter(searchBar.text)
    }

    // The network form holds the user's edits, so it is filled imperatively rather than bound:
    // a binding on `text` is destroyed by the first keystroke and never follows a reload.
    function loadNetworkForm() {
        if (!proxyField) return
        proxyField.text = (config.proxy !== undefined && config.proxy !== null) ? config.proxy : ""
        proxyRequiredSwitch.checked = config.proxyRequired === true
        timeoutField.value = config.timeoutSecs !== undefined ? config.timeoutSecs : 30
    }
    onConfigChanged: loadNetworkForm()
    onSelectedChainIdChanged: if (customChainField)
        customChainField.text = selectedChainId > 0 ? String(selectedChainId) : ""

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                text: "Token Lists"
                color: Theme.palette.text
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
            }

            Item { Layout.fillWidth: true }

            LogosText {
                objectName: "statusText"
                // The only place a dependency that stopped answering becomes visible.
                textFormat: Text.PlainText
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                text: root.ready ? root.backend.statusText : "Starting"
            }
            LogosBadge {
                objectName: "stateBadge"
                text: root.stateText(root.configState)
                color: root.stateColor(root.configState)
            }
            LogosButton {
                objectName: "refreshButton"
                text: "Reload"
                enabled: root.ready && !root.backend.busy
                onClicked: root.backend.refresh()
            }
        }

        LogosText {
            objectName: "deviceWideNote"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            text: "Token names, symbols and decimals are stored once for this device and used "
                + "by every Logos wallet on it. This is metadata only — it can never add a "
                + "token to a wallet that does not already offer it."
        }

        LogosText {
            objectName: "errorLabel"
            Layout.fillWidth: true
            visible: root.ready && root.backend.lastError.length > 0
            // Backend-authored; may contain anything.
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Theme.palette.error
            text: root.ready ? root.backend.lastError : ""
        }

        LogosText {
            objectName: "formError"
            Layout.fillWidth: true
            visible: root.formError.length > 0
            wrapMode: Text.WordWrap
            color: Theme.palette.error
            text: root.formError
        }

        // ── starting ──────────────────────────────────────────────────────────────────
        LogosText {
            objectName: "startingNote"
            Layout.fillWidth: true
            visible: root.configState === "unready"
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            // "Starting" is not "unconfigured": offering to initialize a module that has not
            // finished starting is exactly the conflation this panel avoids.
            text: "Waiting for the token list module to finish starting…"
        }

        // ── nothing configured yet ────────────────────────────────────────────────────
        LogosFrame {
            objectName: "initDefaultsCard"
            Layout.fillWidth: true
            visible: root.configState === "unconfigured"
            contentItem: ColumnLayout {
                spacing: Theme.spacing.small

                LogosText {
                    text: "No token list is configured on this device"
                    color: Theme.palette.text
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.secondaryText
                    text: "The built-in defaults switch on the Uniswap list that ships inside "
                        + "the module. No URL is fetched, nothing is scheduled, and no request "
                        + "leaves this device."
                }
                LogosButton {
                    objectName: "initDefaultsButton"
                    text: "Use the built-in Uniswap list (offline)"
                    enabled: root.ready && !root.backend.busy
                    onClicked: root.backend.initDefaults()
                }
            }
        }

        // ── configured ────────────────────────────────────────────────────────────────
        LogosTabBar {
            id: tabs
            objectName: "tabs"
            Layout.fillWidth: true
            visible: root.configState === "configured"
            LogosTabButton { objectName: "tokensTab"; text: "Tokens" }
            LogosTabButton { objectName: "listsTab"; text: "Lists and network" }
            LogosTabButton { objectName: "customTab"; text: "Custom tokens" }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.configState === "configured"
            currentIndex: tabs.currentIndex

            // ── tokens ────────────────────────────────────────────────────────────────
            ColumnLayout {
                spacing: Theme.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosComboBox {
                        id: chainPicker
                        objectName: "chainPicker"
                        Layout.preferredWidth: 260
                        model: root.chains.map(function (c) { return root.chainLabel(c) })
                        enabled: root.ready && root.chains.length > 0
                        // Assigned, never bound: selecting a row writes currentIndex
                        // internally, which destroys a declarative binding.
                        onModelChanged: currentIndex = root.chainIndex
                        onActivated: if (root.ready)
                            root.backend.selectChain(root.chains[currentIndex].chainId)
                    }

                    LogosBadge {
                        objectName: "embeddedCount"
                        visible: root.counts.embedded !== undefined
                        text: "built-in " + root.counts.embedded
                        color: Theme.palette.primary
                    }
                    LogosBadge {
                        objectName: "downloadedCount"
                        visible: root.counts.downloaded !== undefined
                        text: "downloaded " + root.counts.downloaded
                        color: Theme.palette.textTertiary
                    }
                    LogosBadge {
                        objectName: "customCount"
                        visible: root.counts.custom !== undefined
                        text: "custom " + root.counts.custom
                        color: Theme.palette.accentOrange
                    }

                    Item { Layout.fillWidth: true }

                    LogosSearchBar {
                        id: searchBar
                        objectName: "searchBar"
                        Layout.preferredWidth: 280
                        placeholderText: "Filter by symbol, name or address"
                        onTextChanged: filterDebounce.restart()
                        onSubmitted: if (root.ready) root.backend.setFilter(text)
                    }
                }

                LogosText {
                    objectName: "noTokensNote"
                    Layout.fillWidth: true
                    visible: root.chains.length === 0
                    wrapMode: Text.WordWrap
                    color: Theme.palette.textSecondary
                    text: "No tokens are loaded. Switch the built-in list back on, add a list "
                        + "URL and fetch it, or add a custom token."
                }

                LogosTable {
                    objectName: "tokenTable"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.chains.length > 0
                    model: pageRows
                    rowHeight: 44
                    emptyText: "No token matches this filter"

                    columns: [
                        LogosTableColumn {
                            title: "Symbol"; role: "symbol"; minWidth: 90; preferredWidth: 110
                            cellDelegate: plainCell
                        },
                        LogosTableColumn {
                            title: "Name"; role: "name"; minWidth: 140; preferredWidth: 220
                            fillWidth: true; cellDelegate: plainCell
                        },
                        LogosTableColumn {
                            title: "Contract address"; role: "address"
                            minWidth: 240; preferredWidth: 380; cellDelegate: plainCell
                        },
                        LogosTableColumn {
                            title: "Dec"; role: "decimals"; minWidth: 60; preferredWidth: 60
                            alignment: Qt.AlignRight | Qt.AlignVCenter; cellDelegate: plainCell
                        },
                        LogosTableColumn {
                            title: "From"; role: "source"; minWidth: 110; preferredWidth: 120
                            cellDelegate: sourceCell
                        },
                        LogosTableColumn {
                            title: ""; role: "source"; minWidth: 90; preferredWidth: 90
                            cellDelegate: removeCell
                        }
                    ]
                }

                LogosPaginator {
                    objectName: "paginator"
                    Layout.fillWidth: true
                    visible: root.pageTotal > 0
                    totalCount: root.pageTotal
                    pageSize: root.pageLimit
                    currentPage: Math.floor(root.pageOffset / Math.max(1, root.pageLimit)) + 1
                    pageSizeOptions: [25, 50, 100]
                    pageInfoText: root.pageTotal + " tokens"
                    onPageRequested: function (p) {
                        root.backend.setPage((p - 1) * root.pageLimit, root.pageLimit)
                    }
                    onPageSizeRequested: function (s) { root.backend.setPage(0, s) }
                }
            }

            // ── lists and network ─────────────────────────────────────────────────────
            LogosScrollView {
                ColumnLayout {
                    width: parent.width
                    spacing: Theme.spacing.small

                    LogosFrame {
                        Layout.fillWidth: true
                        contentItem: ColumnLayout {
                            spacing: Theme.spacing.small

                            LogosSwitch {
                                id: embeddedSwitch
                                objectName: "embeddedSwitch"
                                text: "Use the token list built into the module"
                                enabled: root.ready && !root.backend.busy
                                onToggled: root.backend.setUseEmbeddedList(checked)
                            }
                            // A refused change must snap the switch back: toggling writes
                            // `checked` internally, which destroys a plain binding.
                            Binding {
                                target: embeddedSwitch
                                property: "checked"
                                value: root.config.useEmbeddedList === true
                                restoreMode: Binding.RestoreNone
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "A frozen snapshot of the Uniswap default list, shipped "
                                    + "inside the module. It needs no network and it is the "
                                    + "lowest-priority source: anything you download or add "
                                    + "yourself wins over it."
                            }
                        }
                    }

                    LogosFrame {
                        Layout.fillWidth: true
                        contentItem: ColumnLayout {
                            spacing: Theme.spacing.small

                            LogosText { text: "Extra list URLs"; color: Theme.palette.textSecondary }

                            LogosText {
                                Layout.fillWidth: true
                                visible: root.listUrls.length === 0
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "None. The module fetches nothing at all until one is added."
                            }

                            Repeater {
                                model: root.listUrls
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.small
                                    LogosText {
                                        Layout.fillWidth: true
                                        // A URL the user typed.
                                        textFormat: Text.PlainText
                                        elide: Text.ElideMiddle
                                        color: Theme.palette.text
                                        font.pixelSize: Theme.typography.secondaryText
                                        text: modelData
                                    }
                                    LogosButton {
                                        text: "Remove"
                                        enabled: root.ready && !root.backend.busy
                                        onClicked: root.backend.removeListUrl(modelData)
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosTextField {
                                    id: listUrlField
                                    objectName: "listUrlField"
                                    Layout.fillWidth: true
                                    placeholderText: "https://…/tokenlist.json"
                                }
                                LogosButton {
                                    objectName: "addListUrlButton"
                                    text: "Add"
                                    enabled: root.ready && !root.backend.busy
                                    onClicked: {
                                        root.backend.addListUrl(listUrlField.text)
                                        listUrlField.text = ""
                                    }
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "Adding a URL only stores it. Nothing is downloaded until "
                                    + "you press Fetch now, and nothing re-fetches on its own — "
                                    + "no part of the platform schedules a refresh."
                            }

                            RowLayout {
                                spacing: Theme.spacing.small
                                LogosButton {
                                    objectName: "fetchNowButton"
                                    text: "Fetch now"
                                    enabled: root.ready && !root.backend.busy
                                             && root.listUrls.length > 0
                                    onClicked: root.backend.refreshNow()
                                }
                                LogosText {
                                    objectName: "fetchResult"
                                    visible: text.length > 0
                                    // Carries token_list's own transport error.
                                    textFormat: Text.PlainText
                                    color: root.lastFetch.ok === true ? Theme.palette.success
                                                                      : Theme.palette.error
                                    font.pixelSize: Theme.typography.secondaryText
                                    text: root.lastFetch.ok === undefined ? ""
                                        : root.lastFetch.ok
                                          ? root.lastFetch.tokenCount + " tokens at " + root.lastFetch.at
                                          : "Failed at " + root.lastFetch.at + ": " + root.lastFetch.error
                                }
                            }

                            Repeater {
                                model: root.sources
                                LogosText {
                                    Layout.fillWidth: true
                                    // Names and errors come from a document at a URL the user
                                    // typed — never HTML-autodetected.
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: modelData.ok ? Theme.palette.textSecondary
                                                        : Theme.palette.error
                                    text: modelData.ok
                                        ? modelData.name + " — " + modelData.tokenCount + " tokens"
                                        : modelData.url + " — " + (modelData.error || "failed")
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                visible: root.sources.length === 0 && root.listUrls.length > 0
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "Per-URL results appear after a fetch. They are not kept "
                                    + "across restarts, so an empty list here does not mean a "
                                    + "URL failed."
                            }
                        }
                    }

                    LogosFrame {
                        Layout.fillWidth: true
                        contentItem: ColumnLayout {
                            spacing: Theme.spacing.small

                            LogosText { text: "Network"; color: Theme.palette.textSecondary }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosTextField {
                                    id: proxyField
                                    objectName: "proxyField"
                                    Layout.fillWidth: true
                                    placeholderText: "socks5h://127.0.0.1:9050"
                                }
                                LogosSwitch {
                                    id: proxyRequiredSwitch
                                    objectName: "proxyRequiredSwitch"
                                    text: "Required"
                                }
                                LogosButton {
                                    objectName: "saveProxyButton"
                                    text: "Save proxy"
                                    enabled: root.ready && !root.backend.busy
                                    onClicked: root.backend.setProxy(proxyField.text,
                                                                     proxyRequiredSwitch.checked)
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.secondaryText
                                visible: proxyRequiredSwitch.checked && proxyField.text.trim().length === 0
                                text: "Required with no proxy set is fail-closed: every fetch is "
                                    + "refused rather than sent in the clear. That is a valid "
                                    + "choice, but Fetch now will always fail until a proxy is set."
                            }

                            RowLayout {
                                spacing: Theme.spacing.small
                                LogosText { text: "Timeout (seconds)"; color: Theme.palette.textSecondary }
                                LogosSpinBox {
                                    id: timeoutField
                                    objectName: "timeoutField"
                                    from: 1
                                    to: 300
                                }
                                LogosButton {
                                    objectName: "saveTimeoutButton"
                                    text: "Save timeout"
                                    enabled: root.ready && !root.backend.busy
                                    onClicked: root.backend.setTimeout(timeoutField.value)
                                }
                            }
                        }
                    }
                }
            }

            // ── custom tokens ─────────────────────────────────────────────────────────
            LogosScrollView {
                ColumnLayout {
                    width: parent.width
                    spacing: Theme.spacing.small

                    LogosFrame {
                        Layout.fillWidth: true
                        contentItem: ColumnLayout {
                            spacing: Theme.spacing.small

                            LogosText {
                                text: "Add a token by contract address"
                                color: Theme.palette.textSecondary
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosTextField {
                                    id: customChainField
                                    objectName: "customChainField"
                                    Layout.preferredWidth: 120
                                    placeholderText: "chain id"
                                }
                                LogosTextField {
                                    id: customAddressField
                                    objectName: "customAddressField"
                                    Layout.fillWidth: true
                                    placeholderText: "0x…"
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosTextField {
                                    id: customSymbolField
                                    objectName: "customSymbolField"
                                    Layout.preferredWidth: 120
                                    placeholderText: "symbol"
                                }
                                LogosTextField {
                                    id: customNameField
                                    objectName: "customNameField"
                                    Layout.fillWidth: true
                                    placeholderText: "name"
                                }
                                LogosSpinBox {
                                    id: customDecimalsField
                                    objectName: "customDecimalsField"
                                    from: 0
                                    to: 36
                                    value: 18
                                }
                                LogosButton {
                                    objectName: "addCustomTokenButton"
                                    text: "Add"
                                    enabled: root.ready && !root.backend.busy
                                    onClicked: {
                                        root.formError = ""
                                        var chain = parseInt(customChainField.text.trim(), 10)
                                        var addr = customAddressField.text.trim()
                                        if (!(chain > 0) || chain > 2147483647) {
                                            root.formError = "Enter a chain id: a whole number from 1 to 2147483647."
                                            return
                                        }
                                        if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) {
                                            root.formError = "Enter a contract address: 0x followed by 40 hex characters."
                                            return
                                        }
                                        root.backend.addCustomToken(JSON.stringify({
                                            chainId: chain,
                                            address: addr,
                                            name: customNameField.text.trim(),
                                            symbol: customSymbolField.text.trim(),
                                            decimals: customDecimalsField.value
                                        }))
                                        customAddressField.text = ""
                                        customSymbolField.text = ""
                                        customNameField.text = ""
                                    }
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "Nothing here is verified against the chain. A wrong "
                                    + "decimals value makes every balance shown for that token "
                                    + "wrong by a factor of ten, and a wallet still decides for "
                                    + "itself whether it offers the token at all."
                            }
                        }
                    }

                    LogosFrame {
                        Layout.fillWidth: true
                        contentItem: ColumnLayout {
                            spacing: Theme.spacing.small

                            LogosText {
                                text: "Import a token-list document"
                                color: Theme.palette.textSecondary
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                text: "Paste a Uniswap-schema list and it becomes your custom "
                                    + "tokens in one write. No URL is contacted."
                            }
                            LogosButton {
                                objectName: "openImportButton"
                                text: "Paste a list…"
                                enabled: root.ready && !root.backend.busy
                                onClicked: importDialog.open()
                            }
                        }
                    }
                }
            }
        }
    }

    // ── table cell delegates ──────────────────────────────────────────────────────────
    Component {
        id: plainCell
        Item {
            LogosText {
                anchors.fill: parent
                // Token metadata, straight from a list document.
                textFormat: Text.PlainText
                text: rowItem && rowItem[columnDef.role] !== undefined
                      ? rowItem[columnDef.role] + "" : ""
                color: Theme.palette.text
                font.pixelSize: Theme.typography.secondaryText
                horizontalAlignment: (columnDef.alignment & Qt.AlignRight) ? Text.AlignRight
                                                                           : Text.AlignLeft
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideMiddle
            }
        }
    }

    Component {
        id: sourceCell
        Item {
            LogosBadge {
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem ? rowItem.source : ""
                color: rowItem && rowItem.source === "custom" ? Theme.palette.accentOrange
                     : rowItem && rowItem.source === "downloaded" ? Theme.palette.primary
                                                                  : Theme.palette.textTertiary
            }
        }
    }

    Component {
        id: removeCell
        Item {
            LogosButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: rowItem && rowItem.source === "custom"
                text: "Remove"
                enabled: root.ready && !root.backend.busy
                onClicked: root.backend.removeCustomToken(root.selectedChainId, rowItem.address)
            }
        }
    }

    // ── import dialog ─────────────────────────────────────────────────────────────────
    LogosDialog {
        id: importDialog
        objectName: "importDialog"
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 560)
        title: "Paste a token-list document"

        contentItem: ColumnLayout {
            spacing: Theme.spacing.small

            LogosScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 200
                LogosTextArea {
                    id: importArea
                    objectName: "importArea"
                    placeholderText: "{ \"name\": \"…\", \"tokens\": [ … ] }"
                }
            }
            LogosSwitch {
                id: importReplace
                objectName: "importReplace"
                text: "Replace my custom tokens instead of merging"
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.palette.warning
                font.pixelSize: Theme.typography.secondaryText
                visible: importReplace.checked
                text: "Replace discards every custom token you have added on this device."
            }
        }

        leftActions: [
            LogosButton {
                objectName: "importCancel"
                text: "Cancel"
                onClicked: importDialog.close()
            }
        ]
        rightActions: [
            LogosButton {
                objectName: "importConfirm"
                text: "Import"
                onClicked: {
                    root.backend.importCustomTokens(importArea.text, importReplace.checked)
                    importArea.text = ""
                    importDialog.close()
                }
            }
        ]
    }
}
