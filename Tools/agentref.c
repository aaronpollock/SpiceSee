#include <spice/vd_agent.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void dump(const char *name, const void *p, size_t n) {
    printf("%-24s ", name);
    for (size_t i = 0; i < n; i++) printf("%02x", ((const unsigned char *)p)[i]);
    printf("\n");
}

int main(void) {
    printf("sizeof(VDAgentMessage)        = %zu\n", sizeof(VDAgentMessage));
    printf("VD_AGENT_MAX_DATA_SIZE        = %d\n", VD_AGENT_MAX_DATA_SIZE);
    printf("VD_AGENT_PROTOCOL             = %d\n", VD_AGENT_PROTOCOL);
    printf("VD_AGENT_CAPS_SIZE            = %d\n", VD_AGENT_CAPS_SIZE);
    printf("VD_AGENT_CAPS_BYTES           = %d\n", VD_AGENT_CAPS_BYTES);
    printf("sizeof(VDAgentClipboard)      = %zu\n", sizeof(VDAgentClipboard));
    printf("sizeof(VDAgentClipboardGrab)  = %zu\n", sizeof(VDAgentClipboardGrab));
    printf("type CLIPBOARD=%d GRAB=%d REQUEST=%d RELEASE=%d CAPS=%d\n",
           VD_AGENT_CLIPBOARD, VD_AGENT_CLIPBOARD_GRAB, VD_AGENT_CLIPBOARD_REQUEST,
           VD_AGENT_CLIPBOARD_RELEASE, VD_AGENT_ANNOUNCE_CAPABILITIES);
    printf("cap BY_DEMAND=%d SELECTION=%d CRLF=%d\n",
           VD_AGENT_CAP_CLIPBOARD_BY_DEMAND, VD_AGENT_CAP_CLIPBOARD_SELECTION,
           VD_AGENT_CAP_GUEST_LINEEND_CRLF);
    printf("clip UTF8=%d PNG=%d\n", VD_AGENT_CLIPBOARD_UTF8_TEXT, VD_AGENT_CLIPBOARD_IMAGE_PNG);

    /* A whole MAIN_AGENT_DATA stream for ANNOUNCE_CAPABILITIES, exactly as
       spice-gtk's agent_announce_caps + agent_msg_queue_many build it. */
    size_t capsize = sizeof(VDAgentAnnounceCapabilities) + VD_AGENT_CAPS_BYTES;
    VDAgentAnnounceCapabilities *caps = calloc(1, capsize);
    caps->request = 1;
    VD_AGENT_SET_CAPABILITY(caps->caps, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
    VD_AGENT_SET_CAPABILITY(caps->caps, VD_AGENT_CAP_CLIPBOARD_SELECTION);
    unsigned char buf[512];
    VDAgentMessage msg = { .protocol = VD_AGENT_PROTOCOL, .type = VD_AGENT_ANNOUNCE_CAPABILITIES,
                           .opaque = 0, .size = capsize };
    memcpy(buf, &msg, sizeof msg);
    memcpy(buf + sizeof msg, caps, capsize);
    dump("announce_caps", buf, sizeof msg + capsize);
    free(caps);

    /* CLIPBOARD_GRAB, selection prefix present, types = { UTF8_TEXT } */
    size_t gsize = sizeof(uint32_t) /* selection */ + sizeof(uint32_t) /* one type */;
    unsigned char g[16]; memset(g, 0, sizeof g);
    g[0] = VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD;
    VDAgentClipboardGrab *grab = (VDAgentClipboardGrab *)(g + 4);
    grab->types[0] = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    msg.type = VD_AGENT_CLIPBOARD_GRAB; msg.size = gsize;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, g, gsize);
    dump("clipboard_grab", buf, sizeof msg + gsize);

    /* CLIPBOARD_REQUEST, selection prefix present, type = UTF8_TEXT */
    size_t rsize = 4 + sizeof(VDAgentClipboardRequest);
    unsigned char rq[16]; memset(rq, 0, sizeof rq);
    rq[0] = VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD;
    ((VDAgentClipboardRequest *)(rq + 4))->type = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    msg.type = VD_AGENT_CLIPBOARD_REQUEST; msg.size = rsize;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, rq, rsize);
    dump("clipboard_request", buf, sizeof msg + rsize);

    /* CLIPBOARD, selection prefix present, UTF8 "hi\n" */
    const char *text = "hi\n";
    size_t csize = 4 + sizeof(VDAgentClipboard) + strlen(text);
    unsigned char cb[32]; memset(cb, 0, sizeof cb);
    cb[0] = VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD;
    ((VDAgentClipboard *)(cb + 4))->type = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    memcpy(cb + 4 + sizeof(VDAgentClipboard), text, strlen(text));
    msg.type = VD_AGENT_CLIPBOARD; msg.size = csize;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, cb, csize);
    dump("clipboard_utf8", buf, sizeof msg + csize);

    /* CLIPBOARD_RELEASE, selection prefix present */
    unsigned char rel[4] = { VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, 0, 0, 0 };
    msg.type = VD_AGENT_CLIPBOARD_RELEASE; msg.size = 4;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, rel, 4);
    dump("clipboard_release", buf, sizeof msg + 4);

    /* MONITORS_CONFIG, flags=USE_POS: one enabled 1920x1080 head, then a
       sparse two-head config whose second head is disabled (all zeros). */
    printf("sizeof(VDAgentMonitorsConfig) = %zu\n", sizeof(VDAgentMonitorsConfig));
    printf("sizeof(VDAgentMonConfig)      = %zu\n", sizeof(VDAgentMonConfig));
    printf("flag USE_POS=%d cap MONITORS=%d SPARSE=%d\n",
           VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS,
           VD_AGENT_CAP_MONITORS_CONFIG, VD_AGENT_CAP_SPARSE_MONITORS_CONFIG);

    size_t msize = sizeof(VDAgentMonitorsConfig) + sizeof(VDAgentMonConfig);
    VDAgentMonitorsConfig *mc = calloc(1, msize);
    mc->num_of_monitors = 1;
    mc->flags = VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS;
    VDAgentMonConfig *mon = (VDAgentMonConfig *)(mc + 1);
    mon->width = 1920; mon->height = 1080; mon->depth = 32; mon->x = 0; mon->y = 0;
    msg.type = VD_AGENT_MONITORS_CONFIG; msg.size = msize;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, mc, msize);
    dump("monitors_config_1", buf, sizeof msg + msize);
    free(mc);

    size_t m2size = sizeof(VDAgentMonitorsConfig) + 2 * sizeof(VDAgentMonConfig);
    VDAgentMonitorsConfig *mc2 = calloc(1, m2size);
    mc2->num_of_monitors = 2;
    mc2->flags = VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS;
    VDAgentMonConfig *mons = (VDAgentMonConfig *)(mc2 + 1);
    mons[0].width = 2560; mons[0].height = 1440; mons[0].depth = 32;
    mons[0].x = 0; mons[0].y = 0;
    /* mons[1] stays calloc-zero: a disabled head in a sparse config */
    msg.type = VD_AGENT_MONITORS_CONFIG; msg.size = m2size;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, mc2, m2size);
    dump("monitors_config_sparse", buf, sizeof msg + m2size);
    free(mc2);
    return 0;
}
