// The app's window in DSM: an iframe showing panel.html, served by DSM behind its sign-in.
Ext.ns("@NS@");
Ext.define("@APPID@", { extend: "SYNO.SDS.AppInstance", appWindowName: "@APPID_WIN@" });
Ext.define("@APPID_WIN@", {
    extend: "SYNO.SDS.AppWindow",
    constructor: function (config) {
        this.callParent([Ext.apply({ title: "@TITLE@", width: 960, height: 680, minWidth: 520, minHeight: 380, resizable: true, maximizable: true, minimizable: true, layout: "fit",
            items: [{ xtype: "box", autoEl: { tag: "iframe", src: "/webman/3rdparty/@PKG@/panel.html", frameborder: 0, style: "width:100%;height:100%;border:0;display:block" } }] }, config)]);
    }
});
