#include "token_list_ui_backend.h"

#include <algorithm>
#include <limits>

#include <QDateTime>
#include <QJsonDocument>
#include <QMap>
#include <QUrl>

// The generated umbrella carrying `struct LogosModules` — without it `modules()` is an
// incomplete type and every dependency call fails to compile.
#include "logos_sdk.h"

namespace {

// token_list answers config_status from memory, so a slow poll only delays the first paint.
constexpr int kReadyPollMs = 1500;
// config_status is a local read, and an UNLOADED dependency costs the 20s ABI default on the
// GUI thread. 1500ms is the budget eth_rpc chose for its own out-of-graph probe.
constexpr int kStatusBudgetMs = 1500;
// How long a call may be outstanding before its callback is treated as LOST rather than late.
constexpr int kCallBudgetMs = 20000;
// Status reads that learned nothing tolerated (~4.5s) before the panel says so.
constexpr int kMaxSilentReads = 3;

// Display names only. NOT an allowlist and NOT a security boundary: a chain id absent from
// this table renders as "Chain 4663" with no name claim at all.
struct KnownChain
{
    int id;
    const char *name;
};
constexpr KnownChain kKnownChains[] = {
    {1, "Ethereum"},      {10, "OP Mainnet"},    {56, "BNB Smart Chain"},
    {130, "Unichain"},    {137, "Polygon"},      {324, "zkSync Era"},
    {480, "World Chain"}, {8453, "Base"},        {42161, "Arbitrum One"},
    {42220, "Celo"},      {43114, "Avalanche"},  {81457, "Blast"},
    {7777777, "Zora"},    {5, "Goerli"},         {11155111, "Sepolia"},
    {560048, "Hoodi"},
};

const char *knownName(int id)
{
    for (const KnownChain &k : kKnownChains)
        if (k.id == id)
            return k.name;
    return nullptr;
}

QJsonObject parseObject(const QString &reply)
{
    return QJsonDocument::fromJson(reply.toUtf8()).object();
}

bool replyOk(const QString &reply)
{
    return parseObject(reply).value(QStringLiteral("ok")).toBool();
}

QString replyError(const QString &reply)
{
    const QString e = parseObject(reply).value(QStringLiteral("error")).toString();
    return e.isEmpty() ? QStringLiteral("token_list refused the request") : e;
}

QString compact(const QJsonObject &o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString compact(const QJsonArray &a)
{
    return QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact));
}

/// One page row. `logoURI` is dropped HERE: the ui_qml sandbox refuses a remote fetch and the
/// only trace is one line in the host log, so 88% of rows would fail invisibly.
QJsonObject pageRow(const QJsonObject &token)
{
    return QJsonObject{
        {QStringLiteral("address"), token.value(QStringLiteral("address")).toString()},
        {QStringLiteral("name"), token.value(QStringLiteral("name")).toString()},
        {QStringLiteral("symbol"), token.value(QStringLiteral("symbol")).toString()},
        {QStringLiteral("decimals"), token.value(QStringLiteral("decimals")).toInt()},
        {QStringLiteral("source"), token.value(QStringLiteral("source")).toString()},
    };
}

bool rowMatches(const QJsonObject &row, const QString &needle)
{
    if (needle.isEmpty())
        return true;
    for (const char *key : {"address", "name", "symbol"})
        if (row.value(QLatin1String(key)).toString().contains(needle, Qt::CaseInsensitive))
            return true;
    return false;
}

/// token_list's ListSource derives Serialize with no `rename_all` (rust-lib/src/tokens.rs:55),
/// so the count arrives as `token_count`; accept the camelCase spelling too.
int sourceCount(const QJsonObject &s)
{
    if (s.contains(QStringLiteral("tokenCount")))
        return s.value(QStringLiteral("tokenCount")).toInt();
    return s.value(QStringLiteral("token_count")).toInt();
}

bool usableProxyScheme(const QString &url)
{
    const QString s = QUrl(url).scheme();
    return s == QLatin1String("socks5h") || s == QLatin1String("socks5")
        || s == QLatin1String("http") || s == QLatin1String("https");
}

} // namespace

bool TokenListUiBackend::failed(const QString &reply, const QString &context)
{
    if (replyOk(reply))
        return false;
    setLastError(QStringLiteral("%1: %2").arg(context, replyError(reply)));
    return true;
}

void TokenListUiBackend::onContextReady()
{
    m_readyPoll.setInterval(kReadyPollMs);
    QObject::connect(&m_readyPoll, &QTimer::timeout, [this] { refresh(); });
    refresh();
}

void TokenListUiBackend::refresh()
{
    setLastError(QString());
    quint64 slot = 0;
    if (!m_statusInFlight.take(kStatusBudgetMs, &slot))
        return;
    // ASYNC with a budget: a token_list that is not loaded would otherwise block the GUI
    // thread for the ABI's 20s default on every poll.
    modules().token_list_module.config_statusAsyncResult(
        [this, slot](logos::AsyncResult<QString> r) {
            m_statusInFlight.release(slot);
            applyStatus(r.ok() ? r.value : QString());
        },
        Timeout(kStatusBudgetMs));
}

void TokenListUiBackend::applyStatus(const QString &reply)
{
    // A call that did not arrive says nothing about the config, so the last one stands.
    if (reply.isEmpty()) {
        if (++m_statusSilent >= kMaxSilentReads)
            setStatusText(QStringLiteral("The token list module is not answering"));
        m_readyPoll.start();
        return;
    }
    m_statusSilent = 0;
    m_status = parseObject(reply);
    setStatusJson(compact(m_status));

    // A reply carrying no `state` did not answer the contract. "Ask again" is the only safe
    // reading of it — never "nothing is configured".
    const QString state = m_status.value(QStringLiteral("state")).toString();
    if (state.isEmpty() || state == QLatin1String("unready")) {
        setStatusText(QStringLiteral("Starting…"));
        m_readyPoll.start();
        return;
    }
    m_readyPoll.stop();

    // In-memory reads on the module side, reached only once it has answered once.
    setBusy(true);
    reloadSources();
    reloadChains();
    reloadRows();
    setStatusText(state == QLatin1String("configured") ? QStringLiteral("Ready")
                                                       : QStringLiteral("Not configured"));
    setBusy(false);
}

void TokenListUiBackend::reloadSources()
{
    const QJsonObject reply = parseObject(modules().token_list_module.get_list_sources());
    QJsonArray out;
    for (const QJsonValue &v : reply.value(QStringLiteral("sources")).toArray()) {
        const QJsonObject s = v.toObject();
        QJsonObject row{
            {QStringLiteral("url"), s.value(QStringLiteral("url")).toString()},
            {QStringLiteral("name"), s.value(QStringLiteral("name")).toString()},
            {QStringLiteral("tokenCount"), sourceCount(s)},
            {QStringLiteral("ok"), s.value(QStringLiteral("ok")).toBool()},
        };
        const QString e = s.value(QStringLiteral("error")).toString();
        if (!e.isEmpty())
            row[QStringLiteral("error")] = e;
        out.append(row);
    }
    setSourcesJson(compact(out));
}

void TokenListUiBackend::reloadChains()
{
    const QString reply = modules().token_list_module.get_all_tokens();
    if (failed(reply, QStringLiteral("token list"))) {
        setChainsJson(QStringLiteral("[]"));
        return;
    }

    QMap<int, int> counts;
    for (const QJsonValue &v : parseObject(reply).value(QStringLiteral("tokens")).toArray()) {
        // chainId is int on this wire, so an id past 2^31 cannot be selected or paged from
        // here. Dropping it is honest; a row that cannot be acted on is not.
        const qint64 id = v.toObject().value(QStringLiteral("chainId")).toInteger(0);
        if (id > 0 && id <= std::numeric_limits<int>::max())
            counts[static_cast<int>(id)] += 1;
    }

    QList<int> ids = counts.keys();
    std::sort(ids.begin(), ids.end(), [&counts](int a, int b) {
        return counts.value(a) != counts.value(b) ? counts.value(a) > counts.value(b) : a < b;
    });

    QJsonArray chains;
    for (int id : ids) {
        QJsonObject e{{QStringLiteral("chainId"), id}, {QStringLiteral("count"), counts.value(id)}};
        // Absent, never guessed: an unnamed id renders as its number.
        if (const char *n = knownName(id))
            e[QStringLiteral("name")] = QString::fromLatin1(n);
        chains.append(e);
    }
    setChainsJson(compact(chains));

    const bool kept = counts.contains(selectedChainId());
    if (!kept)
        setSelectedChainId(ids.isEmpty() ? 0 : ids.first());
}

void TokenListUiBackend::reloadRows()
{
    m_rows = QJsonArray();
    const int chain = selectedChainId();
    if (chain > 0) {
        const QString reply = modules().token_list_module.get_tokens(chain);
        if (!failed(reply, QStringLiteral("tokens")))
            m_rows = parseObject(reply).value(QStringLiteral("tokens")).toArray();
    }
    publishPage();
}

void TokenListUiBackend::publishPage()
{
    const QString needle = filterText().trimmed();
    QJsonArray matched;
    for (const QJsonValue &v : m_rows) {
        const QJsonObject row = pageRow(v.toObject());
        if (rowMatches(row, needle))
            matched.append(row);
    }

    const int total = matched.size();
    if (m_offset >= total)
        m_offset = 0;

    QJsonArray rows;
    for (int i = m_offset; i < total && i < m_offset + m_limit; ++i)
        rows.append(matched.at(i));

    setPageJson(compact(QJsonObject{
        {QStringLiteral("total"), total},
        {QStringLiteral("offset"), m_offset},
        {QStringLiteral("limit"), m_limit},
        {QStringLiteral("rows"), rows},
    }));
}

void TokenListUiBackend::selectChain(int chainId)
{
    if (chainId <= 0 || chainId == selectedChainId())
        return;
    setSelectedChainId(chainId);
    m_offset = 0;
    reloadRows();
}

void TokenListUiBackend::setFilter(QString text)
{
    setFilterText(text);
    // A filter that shrinks the result set below the current window would otherwise show an
    // empty page with rows sitting above it.
    m_offset = 0;
    publishPage();
}

void TokenListUiBackend::setPage(int offset, int limit)
{
    m_offset = std::max(0, offset);
    m_limit = std::clamp(limit, 1, 500);
    publishPage();
}

QStringList TokenListUiBackend::listUrls() const
{
    QStringList out;
    const QJsonObject cfg = m_status.value(QStringLiteral("config")).toObject();
    for (const QJsonValue &v : cfg.value(QStringLiteral("listUrls")).toArray())
        out.append(v.toString());
    return out;
}

void TokenListUiBackend::patchConfig(const QJsonObject &fields, const QString &context)
{
    setLastError(QString());
    // ONE field per call: the store is shared, and token_list keeps every key this object
    // omits. A whole-record write would silently reset a sibling wallet's proxy.
    if (!modules().token_list_module.configure(compact(fields))) {
        setLastError(QStringLiteral("%1: token_list refused the change").arg(context));
        return;
    }
    refresh();
}

void TokenListUiBackend::writeListUrls(const QStringList &urls, const QString &context)
{
    QJsonArray a;
    for (const QString &u : urls)
        a.append(u);
    patchConfig(QJsonObject{{QStringLiteral("listUrls"), a}}, context);
}

void TokenListUiBackend::setUseEmbeddedList(bool on)
{
    patchConfig(QJsonObject{{QStringLiteral("useEmbeddedList"), on}},
                QStringLiteral("built-in list"));
}

void TokenListUiBackend::addListUrl(QString url)
{
    setLastError(QString());
    const QString trimmed = url.trimmed();
    const QString scheme = QUrl(trimmed).scheme();
    if (scheme != QLatin1String("https") && scheme != QLatin1String("http")) {
        setLastError(QStringLiteral("a list URL must start with https:// or http://"));
        return;
    }
    QStringList urls = listUrls();
    if (urls.contains(trimmed)) {
        setLastError(QStringLiteral("that URL is already on the list"));
        return;
    }
    urls.append(trimmed);
    // Stored only. Nothing is fetched until someone presses Fetch now.
    writeListUrls(urls, QStringLiteral("list URLs"));
}

void TokenListUiBackend::removeListUrl(QString url)
{
    QStringList urls = listUrls();
    if (urls.removeAll(url) == 0) {
        setLastError(QStringLiteral("that URL is not on the list"));
        return;
    }
    writeListUrls(urls, QStringLiteral("list URLs"));
}

void TokenListUiBackend::setProxy(QString proxyUrl, bool required)
{
    setLastError(QString());
    const QString trimmed = proxyUrl.trimmed();
    if (!trimmed.isEmpty() && !usableProxyScheme(trimmed)) {
        setLastError(QStringLiteral("a proxy URL must use socks5h://, socks5://, http:// or "
                                    "https://"));
        return;
    }
    // Explicit null, not omission: "clear the proxy" and "leave it alone" are different
    // requests, and only one of them may drop a Tor proxy the user set.
    const QJsonValue proxy = trimmed.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(trimmed);
    patchConfig(QJsonObject{{QStringLiteral("proxy"), proxy},
                            {QStringLiteral("proxyRequired"), required}},
                QStringLiteral("proxy"));
}

void TokenListUiBackend::setTimeout(int timeoutSecs)
{
    patchConfig(QJsonObject{{QStringLiteral("timeoutSecs"), std::clamp(timeoutSecs, 1, 300)}},
                QStringLiteral("timeout"));
}

void TokenListUiBackend::addCustomToken(QString tokenJson)
{
    setLastError(QString());
    const QJsonObject t = parseObject(tokenJson);
    if (t.value(QStringLiteral("chainId")).toInteger(0) <= 0
        || t.value(QStringLiteral("address")).toString().trimmed().isEmpty()) {
        setLastError(QStringLiteral("a custom token needs a chain id and a contract address"));
        return;
    }
    if (!modules().token_list_module.add_custom_token(compact(t))) {
        setLastError(QStringLiteral("token_list refused that token"));
        return;
    }
    refresh();
}

void TokenListUiBackend::removeCustomToken(int chainId, QString address)
{
    setLastError(QString());
    if (!modules().token_list_module.remove_custom_token(chainId, address)) {
        setLastError(QStringLiteral("that token was not in your custom list"));
        return;
    }
    refresh();
}

void TokenListUiBackend::importCustomTokens(QString listJson, bool replace)
{
    setLastError(QString());
    if (listJson.trimmed().isEmpty()) {
        setLastError(QStringLiteral("paste a token-list document first"));
        return;
    }
    // No network: the caller supplies the bytes.
    if (failed(modules().token_list_module.import_custom_tokens(listJson, replace),
               QStringLiteral("import")))
        return;
    refresh();
}

void TokenListUiBackend::initDefaults()
{
    setLastError(QString());
    const QString reply = modules().token_list_module.init_defaults();
    // `applied: false` means another consumer got there first. That is an answer, not a
    // failure, so only `ok: false` is reported.
    if (failed(reply, QStringLiteral("defaults")))
        return;
    refresh();
}

void TokenListUiBackend::refreshNow()
{
    setLastError(QString());
    quint64 slot = 0;
    if (!m_refreshInFlight.take(kCallBudgetMs, &slot))
        return;
    setBusy(true);
    setStatusText(QStringLiteral("Fetching lists…"));

    // ASYNC deliberately: this runs on the GUI thread and a dead list URL costs the whole
    // configured timeout before it answers.
    modules().token_list_module.refresh_nowAsyncResult(
        [this, slot](logos::AsyncResult<QString> r) {
            m_refreshInFlight.release(slot);
            setBusy(false);

            QJsonObject out{{QStringLiteral("at"),
                             QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss"))}};
            if (!r.ok()) {
                out[QStringLiteral("ok")] = false;
                out[QStringLiteral("error")] = QStringLiteral("token_list did not answer the fetch");
            } else if (replyOk(r.value)) {
                out[QStringLiteral("ok")] = true;
                out[QStringLiteral("tokenCount")] =
                    parseObject(r.value).value(QStringLiteral("tokenCount")).toInteger(0);
            } else {
                out[QStringLiteral("ok")] = false;
                out[QStringLiteral("error")] = replyError(r.value);
            }
            setRefreshJson(compact(out));
            refresh();
        },
        Timeout(kCallBudgetMs));
}
