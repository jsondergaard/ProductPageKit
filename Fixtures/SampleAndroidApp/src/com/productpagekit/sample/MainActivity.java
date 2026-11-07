package com.productpagekit.sample;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.widget.TextView;
import java.util.Locale;

/**
 * Shows the scene ProductPageKit names in the productPageScene extra, in a
 * colour of its own with its name and the app's language, then logs that it
 * is ready, as an app's capture hook does.
 */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String scene = getIntent().getStringExtra("productPageScene");
        String variant = getIntent().getStringExtra("productPageVariant");
        if (scene == null) scene = "inbox";
        TextView view = new TextView(this);
        view.setGravity(Gravity.CENTER);
        view.setTextSize(40);
        view.setTextColor(Color.WHITE);
        view.setBackgroundColor(colour(scene));
        String language = getResources().getConfiguration().getLocales().get(0).toLanguageTag();
        view.setText(scene + (variant == null ? "" : " · " + variant) + "\n" + language);
        setContentView(view);
        final String ready = scene;
        // Once the first frame with the scene in it is drawn.
        view.post(() -> view.postOnAnimation(() -> Log.i("ProductPage", "ready " + ready)));
    }

    private static int colour(String scene) {
        switch (scene) {
            case "inbox": return Color.rgb(31, 42, 68);
            case "detail": return Color.rgb(120, 40, 60);
            default: return Color.rgb(30, 90, 50);
        }
    }
}
