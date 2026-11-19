package com.productpagekit.sample;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.util.function.Supplier;

/**
 * Shows the scene ProductPageKit names in the productPageScene extra, in a
 * colour of its own with its name and the app's language, or the component
 * it names in productPageComponent, a card in the middle of the screen in
 * its state's colour, then logs that it is ready, with the card's rect for a
 * component, as an app's capture hook does.
 */
public class MainActivity extends Activity {
    /** The card's size, in pixels. */
    static final int CARD_WIDTH = 600;
    static final int CARD_HEIGHT = 300;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String scene = getIntent().getStringExtra("productPageScene");
        String variant = getIntent().getStringExtra("productPageVariant");
        String component = getIntent().getStringExtra("productPageComponent");
        if (component != null) {
            String cardState = getIntent().getStringExtra("productPageComponentState");
            TextView card = label(component + (cardState == null ? "" : " · " + cardState), "blue".equals(cardState) ? Color.rgb(40, 80, 200) : Color.rgb(200, 120, 40));
            FrameLayout screen = new FrameLayout(this);
            screen.setBackgroundColor(Color.rgb(20, 20, 24));
            screen.addView(card, new FrameLayout.LayoutParams(CARD_WIDTH, CARD_HEIGHT, Gravity.CENTER));
            setContentView(screen);
            String subject = component + (cardState == null ? "" : "@" + cardState);
            ready(card, () -> {
                int[] origin = new int[2];
                card.getLocationOnScreen(origin);
                return subject + " " + origin[0] + "," + origin[1] + "," + (origin[0] + card.getWidth()) + "," + (origin[1] + card.getHeight());
            });
            return;
        }
        if (scene == null) scene = "inbox";
        String language = getResources().getConfiguration().getLocales().get(0).toLanguageTag();
        TextView view = label(scene + (variant == null ? "" : " · " + variant) + "\n" + language, colour(scene));
        setContentView(view);
        final String subject = scene;
        ready(view, () -> subject);
    }

    private TextView label(String text, int background) {
        TextView view = new TextView(this);
        view.setGravity(Gravity.CENTER);
        view.setTextSize(40);
        view.setTextColor(Color.WHITE);
        view.setBackgroundColor(background);
        view.setText(text);
        return view;
    }

    /** Logs {@code ready} and the line once the first frame with the view in it is drawn. */
    private static void ready(View view, Supplier<String> line) {
        view.post(() -> view.postOnAnimation(() -> Log.i("ProductPage", "ready " + line.get())));
    }

    private static int colour(String scene) {
        switch (scene) {
            case "inbox": return Color.rgb(31, 42, 68);
            case "detail": return Color.rgb(120, 40, 60);
            default: return Color.rgb(30, 90, 50);
        }
    }
}
