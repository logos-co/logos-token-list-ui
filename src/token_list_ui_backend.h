#pragma once

#include <QDeadlineTimer>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>

#include "rep_token_list_ui_source.h"
#include "logos_ui_plugin_context.h"

/// An in-flight claim that EXPIRES. An async callback can simply never fire, so a guard
/// derived from one is a deadline, never a latch.
class InFlight
{
public:
    bool busy() const { return m_held && !m_deadline.hasExpired(); }
    /// Take the slot, or refuse it while the first claim is still live. The ticket identifies
    /// THIS claim, so a completion arriving after its deadline cannot free its replacement.
    bool take(int budgetMs, quint64 *ticket)
    {
        if (busy())
            return false;
        m_held = true;
        m_deadline.setRemainingTime(budgetMs);
        *ticket = ++m_ticket;
        return true;
    }
    void release(quint64 ticket)
    {
        if (ticket == m_ticket)
            m_held = false;
    }

private:
    bool m_held = false;
    quint64 m_ticket = 0;
    QDeadlineTimer m_deadline;
};

// The Token Lists panel's backend.
//
// token_list_module persists its config and its token buckets in its own instance directory,
// and that store is DEVICE-WIDE: every Logos wallet on this device decorates its rows from it.
// Nothing here reaches an account, a balance or a key.
class TokenListUiBackend : public TokenListUiSimpleSource,
                           public LogosUiPluginContext
{
public:
    void refresh() override;
    void selectChain(int chainId) override;
    void setFilter(QString text) override;
    void setPage(int offset, int limit) override;

    void addCustomToken(QString tokenJson) override;
    void removeCustomToken(int chainId, QString address) override;
    void importCustomTokens(QString listJson, bool replace) override;

    void setUseEmbeddedList(bool on) override;
    void addListUrl(QString url) override;
    void removeListUrl(QString url) override;
    void setProxy(QString proxyUrl, bool required) override;
    void setTimeout(int timeoutSecs) override;

    void refreshNow() override;
    void initDefaults() override;

protected:
    void onContextReady() override;

private:
    /// Surface a token_list refusal verbatim. The rule that produced it lives there.
    bool failed(const QString &reply, const QString &context);

    /// Write exactly the named keys through `configure`. Never a whole record: the store is
    /// shared, and an omitted key is token_list's signal to keep what it has.
    void patchConfig(const QJsonObject &fields, const QString &context);

    /// Publish a config_status reply, or count a read that learned nothing. An empty reply
    /// is a call that did not arrive — never evidence that nothing is configured.
    void applyStatus(const QString &reply);
    void reloadSources();
    /// Chain roster + per-chain counts, from one get_all_tokens read.
    void reloadChains();
    /// The selected chain's rows, cached whole so filtering and paging cost no IPC.
    void reloadRows();
    /// Publish the current filter+offset window of m_rows.
    void publishPage();

    /// The stored list URLs, from the last config_status.
    QStringList listUrls() const;
    void writeListUrls(const QStringList &urls, const QString &context);

    QJsonObject m_status;
    QJsonArray m_rows;
    int m_offset = 0;
    int m_limit = 25;

    /// Polls config_status while token_list is still starting. Stopped once it answers.
    QTimer m_readyPoll;
    /// Status reads in a row that learned nothing.
    int m_statusSilent = 0;
    /// One status read at a time; one manual fetch at a time. Both are deadlines, not
    /// latches — a callback that never fires must not wedge the panel shut.
    InFlight m_statusInFlight;
    InFlight m_refreshInFlight;
};
