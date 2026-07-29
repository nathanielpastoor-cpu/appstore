package com.nathaniel.appstore;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.webkit.URLUtil;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.util.HashSet;

/**
 * A thin shell around the live storefront at STORE_URL. The page itself stays
 * on GitHub Pages, so the store's content never requires an update to this
 * app — only the native plumbing lives here:
 *
 *  - APK links download via DownloadManager (a bare WebView drops them), and
 *    a finished download is handed straight to the system installer.
 *  - obtainium:// deep links and off-store websites go to the system
 *    (Obtainium app / browser) instead of loading inside the shell.
 */
public class MainActivity extends Activity {

    private static final String STORE_URL = "https://nathanielpastoor-cpu.github.io/appstore/";
    private static final String STORE_HOST = "nathanielpastoor-cpu.github.io";
    private static final String APK_MIME = "application/vnd.android.package-archive";

    private WebView web;
    private final HashSet<Long> downloadIds = new HashSet<>();
    private BroadcastReceiver onDownloadComplete;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        web = findViewById(R.id.web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true); // the page's "installed / update" badges use localStorage
        web.setBackgroundColor(0xFF0C0A09); // page --bg; avoids a white flash

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri u = request.getUrl();
                String scheme = u.getScheme();
                if ("https".equals(scheme) || "http".equals(scheme)) {
                    String host = u.getHost();
                    if (STORE_HOST.equals(host)) return false; // the store itself
                    // Release-asset downloads hop github.com -> objects.githubusercontent.com;
                    // let the WebView follow so the DownloadListener catches the file.
                    if ("github.com".equals(host) && u.getPath() != null
                            && u.getPath().contains("/releases/download/")) return false;
                    if ("objects.githubusercontent.com".equals(host)) return false;
                }
                // Anything else — web-app cards, Obtainium deep links, docs — leaves the shell.
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, u));
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this,
                            "obtainium".equals(scheme)
                                    ? "Install Obtainium first — see the note at the bottom of the store."
                                    : "No app can open this link.",
                            Toast.LENGTH_LONG).show();
                }
                return true;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) return;
                String html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                        + "<body style='background:#0c0a09;color:#a8a29e;font-family:Georgia,serif;"
                        + "display:flex;min-height:90vh;align-items:center;justify-content:center;text-align:center'>"
                        + "<div><p style='font-size:1.1rem;color:#e7e5e4'>Couldn&rsquo;t reach the store.</p>"
                        + "<p>Check your connection, then</p>"
                        + "<p><a style='color:#34d399' href='" + STORE_URL + "'>try again</a></p></div>";
                view.loadDataWithBaseURL(STORE_URL, html, "text/html", "utf-8", null);
            }
        });

        web.setDownloadListener((url, userAgent, contentDisposition, mimetype, contentLength) -> {
            String name = URLUtil.guessFileName(url, contentDisposition, mimetype);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
            // GitHub serves APKs as octet-stream; the installer needs the real type.
            req.setMimeType(name.toLowerCase().endsWith(".apk") ? APK_MIME : mimetype);
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            req.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
            req.setTitle(name);
            DownloadManager dm = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
            downloadIds.add(dm.enqueue(req));
            Toast.makeText(this, "Downloading " + name + "…", Toast.LENGTH_SHORT).show();
        });

        onDownloadComplete = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                long id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1);
                if (!downloadIds.remove(id)) return; // not ours
                DownloadManager dm = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
                Uri uri = dm.getUriForDownloadedFile(id);
                if (uri == null) {
                    Toast.makeText(MainActivity.this, "Download failed.", Toast.LENGTH_LONG).show();
                    return;
                }
                if (APK_MIME.equals(dm.getMimeTypeForDownloadedFile(id))) {
                    Intent install = new Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, APK_MIME)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    try {
                        startActivity(install);
                    } catch (Exception e) {
                        Toast.makeText(MainActivity.this,
                                "Downloaded — open the notification to install.", Toast.LENGTH_LONG).show();
                    }
                }
            }
        };
        IntentFilter filter = new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(onDownloadComplete, filter, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(onDownloadComplete, filter);
        }

        if (savedInstanceState != null) {
            web.restoreState(savedInstanceState);
        } else {
            web.loadUrl(STORE_URL);
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        if (onDownloadComplete != null) unregisterReceiver(onDownloadComplete);
        super.onDestroy();
    }
}
