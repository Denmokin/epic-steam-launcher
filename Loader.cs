// Loader.cs - fullscreen loading screen shown while a game starts (--loader).
// WPF (GPU-drawn, so zoom/fades are smooth): a slideshow of the game's backgrounds with a slow
// zoom-and-pan and crossfades, the game's logo, a spinning wheel, a status line and a progress bar
// that learns how long each game usually takes (loadtimes.txt next to the exe).
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

static class Loader
{
    public static volatile string Status = "Starting...";
    static float progress = -1f;             // 0..1, or negative = unknown (moving bar)
    public static float Progress { get { return progress; } set { progress = value; } }

    static Thread thread;
    static Dispatcher disp;
    static Window win;
    static Grid root;
    static volatile bool closing;
    static readonly ManualResetEvent started = new ManualResetEvent(false);

    public static bool Visible { get { return win != null && !closing; } }

    public static void Show(string title, IList<string> backgrounds, string logoPath)
    {
        if (thread != null) return;
        thread = new Thread(() =>
        {
            try { Build(title, backgrounds, logoPath); started.Set(); Dispatcher.Run(); }
            catch (Exception e) { try { File.AppendAllText(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "log.txt"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  loader error: " + e.Message + Environment.NewLine); } catch { } closing = true; }
            finally { started.Set(); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        started.WaitOne(8000);
    }

    public static void Close()
    {
        var d = disp;
        if (d == null || closing) { closing = true; return; }
        closing = true;
        try
        {
            d.BeginInvoke((Action)(() =>
            {
                var fade = new DoubleAnimation(root.Opacity, 0, TimeSpan.FromMilliseconds(350));
                fade.Completed += (s, e) => { try { win.Close(); } catch { } d.InvokeShutdown(); };
                root.BeginAnimation(UIElement.OpacityProperty, fade);
            }));
        }
        catch { }
        if (thread != null) thread.Join(2500);
    }

    static BitmapImage LoadImage(string path, int maxWidth)
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;              // don't keep the file locked
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bi.UriSource = new Uri(path);
            if (maxWidth > 0) bi.DecodePixelWidth = maxWidth;
            bi.EndInit();
            bi.Freeze();
            return bi;
        }
        catch { return null; }
    }

    // ---- accent colour: the most common vivid colour of the logo, else of the photos ----
    static Color PickAccent(BitmapSource logo, IList<BitmapImage> photos)
    {
        var sources = new List<BitmapSource>();
        if (logo != null) sources.Add(logo);
        for (int i = 0; i < photos.Count && i < 3; i++) sources.Add(photos[i]);
        for (int i = 0; i < sources.Count; i++) { Color c; if (Vivid(sources[i], logo != null && i == 0 ? 0.002 : 0.01, out c)) return c; }
        return Color.FromRgb(0x4F, 0xC3, 0xF7);
    }

    static bool Vivid(BitmapSource src, double minShare, out Color result)
    {
        result = Colors.White;
        try
        {
            double k = 64.0 / Math.Max(src.PixelWidth, src.PixelHeight);
            BitmapSource small = new TransformedBitmap(src, new ScaleTransform(k, k));
            small = new FormatConvertedBitmap(small, PixelFormats.Bgra32, null, 0);
            int w = small.PixelWidth, h = small.PixelHeight; var px = new byte[w * h * 4];
            small.CopyPixels(px, w * 4, 0);
            var bins = new double[36]; double total = 0;
            for (int i = 0; i < px.Length; i += 4)
            {
                if (px[i + 3] < 128) continue;
                double r = px[i + 2] / 255.0, g = px[i + 1] / 255.0, b = px[i] / 255.0;
                double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min;
                double sat = max == 0 ? 0 : d / max;
                if (sat < 0.35 || max < 0.35) continue;
                double hue = d == 0 ? 0 : max == r ? 60 * (((g - b) / d) % 6) : max == g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4);
                if (hue < 0) hue += 360;
                double wgt = sat * max; bins[(int)(hue / 10) % 36] += wgt; total += wgt;
            }
            if (total < w * h * minShare) return false;   // almost no colour (e.g. a white logo)
            int best = 0; for (int i = 1; i < 36; i++) if (bins[i] > bins[best]) best = i;
            result = FromHsv(best * 10 + 5, 0.72, 1.0);
            return true;
        }
        catch { return false; }
    }

    static Color FromHsv(double h, double s, double v)
    {
        double c = v * s, x = c * (1 - Math.Abs((h / 60) % 2 - 1)), m = v - c, r = 0, g = 0, b = 0;
        if (h < 60) { r = c; g = x; } else if (h < 120) { r = x; g = c; } else if (h < 180) { g = c; b = x; }
        else if (h < 240) { g = x; b = c; } else if (h < 300) { r = x; b = c; } else { r = c; b = x; }
        return Color.FromRgb((byte)((r + m) * 255), (byte)((g + m) * 255), (byte)((b + m) * 255));
    }

    static Color Lighten(Color c, double t)
    {
        return Color.FromRgb((byte)(c.R + (255 - c.R) * t), (byte)(c.G + (255 - c.G) * t), (byte)(c.B + (255 - c.B) * t));
    }

    static void Build(string title, IList<string> backgrounds, string logoPath)
    {
        disp = Dispatcher.CurrentDispatcher;
        double W = SystemParameters.PrimaryScreenWidth, H = SystemParameters.PrimaryScreenHeight;
        int decodeW = (int)Math.Min(3840, W * 1.4);

        var images = new List<BitmapImage>();
        if (backgrounds != null) foreach (var p in backgrounds) { var b = LoadImage(p, decodeW); if (b != null) images.Add(b); }
        // shuffle, so it isn't always the same first picture
        var rnd = new Random();
        for (int i = images.Count - 1; i > 0; i--) { int j = rnd.Next(i + 1); var t = images[i]; images[i] = images[j]; images[j] = t; }

        win = new Window
        {
            WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Topmost = true, ShowInTaskbar = false,
            Background = Brushes.Black, Left = 0, Top = 0, Width = W, Height = H, Cursor = Cursors.None,
            WindowStartupLocation = WindowStartupLocation.Manual, Title = "Loading"
        };
        win.KeyDown += (s, e) => { if (e.Key == Key.Escape) Close(); };

        root = new Grid { ClipToBounds = true, Opacity = 0 };
        win.Content = root;

        // --- slideshow: two layers that crossfade, each slowly zooming and panning ---
        var layers = new[] { new Image { Stretch = Stretch.UniformToFill, Opacity = 0 }, new Image { Stretch = Stretch.UniformToFill, Opacity = 0 } };
        foreach (var l in layers)
        {
            RenderOptions.SetBitmapScalingMode(l, BitmapScalingMode.HighQuality);
            l.RenderTransformOrigin = new Point(0.5, 0.5);
            var tg = new TransformGroup(); tg.Children.Add(new ScaleTransform(1, 1)); tg.Children.Add(new TranslateTransform(0, 0));
            l.RenderTransform = tg;
            root.Children.Add(l);
        }
        int next = 0, front = 1;
        double slide = 7.0, fadeIn = 1.6;
        Action showNext = () =>
        {
            if (images.Count == 0) return;
            var img = layers[1 - front]; var old = layers[front]; front = 1 - front;
            img.Source = images[next % images.Count]; next++;
            Panel.SetZIndex(img, -1); Panel.SetZIndex(old, -2);   // photos always below logo/wheel/text
            var tg = (TransformGroup)img.RenderTransform;
            var sc = (ScaleTransform)tg.Children[0]; var tr = (TranslateTransform)tg.Children[1];
            // Ken Burns: zoom in (or out) a little, drifting in a random direction
            bool zoomIn = rnd.Next(2) == 0;
            double from = zoomIn ? 1.04 : 1.16, to = zoomIn ? 1.16 : 1.04;
            var dur = new Duration(TimeSpan.FromSeconds(slide + fadeIn + 1));
            var zoom = new DoubleAnimation(from, to, dur);
            sc.BeginAnimation(ScaleTransform.ScaleXProperty, zoom); sc.BeginAnimation(ScaleTransform.ScaleYProperty, zoom);
            double dx = W * 0.03 * (rnd.NextDouble() * 2 - 1), dy = H * 0.03 * (rnd.NextDouble() * 2 - 1);
            tr.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-dx, dx, dur));
            tr.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-dy, dy, dur));
            img.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(fadeIn)));
            if (old.Source != null)
            {
                var o = new DoubleAnimation(1, 0, TimeSpan.FromSeconds(fadeIn)) { BeginTime = TimeSpan.FromSeconds(fadeIn * 0.5) };
                old.BeginAnimation(UIElement.OpacityProperty, o);
            }
        };
        showNext();
        if (images.Count > 1)
        {
            var slideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(slide) };
            slideTimer.Tick += (s, e) => showNext();
            slideTimer.Start();
        }

        // --- shading: soft overall dim, vignette around the edges, dark floor for the bottom strip ---
        root.Children.Add(new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(80, 0, 0, 0)) });
        var vignette = new RadialGradientBrush { Center = new Point(0.5, 0.42), GradientOrigin = new Point(0.5, 0.42), RadiusX = 0.8, RadiusY = 0.85 };
        vignette.GradientStops.Add(new GradientStop(Color.FromArgb(0, 0, 0, 0), 0.45));
        vignette.GradientStops.Add(new GradientStop(Color.FromArgb(190, 0, 0, 0), 1.0));
        root.Children.Add(new Rectangle { Fill = vignette });
        var floor = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        floor.GradientStops.Add(new GradientStop(Color.FromArgb(0, 0, 0, 0), 0.55));
        floor.GradientStops.Add(new GradientStop(Color.FromArgb(150, 0, 0, 0), 0.8));
        floor.GradientStops.Add(new GradientStop(Color.FromArgb(245, 0, 0, 0), 1.0));
        root.Children.Add(new Rectangle { Fill = floor });

        var logo = logoPath != null && File.Exists(logoPath) ? LoadImage(logoPath, 0) : null;
        Color accent = PickAccent(logo, images);
        var font = new FontFamily("Segoe UI Variable Display, Segoe UI");
        Func<double, System.Windows.Media.Effects.DropShadowEffect> shadow = b => new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = b, ShadowDepth = 0, Opacity = 0.75, Color = Colors.Black };

        // --- logo (or the title as text), fades and settles in ---
        var logoBox = new Grid { Height = H * 0.30, Width = W * 0.46, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, H * 0.40 - H * 0.15, 0, 0), Opacity = 0 };
        if (logo != null)
        {
            var li = new Image { Source = logo, Stretch = Stretch.Uniform };
            RenderOptions.SetBitmapScalingMode(li, BitmapScalingMode.HighQuality);
            li.Effect = shadow(40);
            logoBox.Children.Add(li);
        }
        else
        {
            logoBox.Width = W * 0.8;
            logoBox.Children.Add(new TextBlock
            {
                Text = title ?? "", Foreground = Brushes.White, FontFamily = font, FontWeight = FontWeights.Bold,
                FontSize = H / 14, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center, Effect = shadow(30)
            });
        }
        var logoScale = new ScaleTransform(0.94, 0.94); logoBox.RenderTransformOrigin = new Point(0.5, 0.5); logoBox.RenderTransform = logoScale;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        logoBox.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(900)) { BeginTime = TimeSpan.FromMilliseconds(200), EasingFunction = ease });
        var settle = new DoubleAnimation(0.94, 1, TimeSpan.FromMilliseconds(1400)) { BeginTime = TimeSpan.FromMilliseconds(200), EasingFunction = ease };
        logoScale.BeginAnimation(ScaleTransform.ScaleXProperty, settle); logoScale.BeginAnimation(ScaleTransform.ScaleYProperty, settle);
        root.Children.Add(logoBox);

        // --- bottom strip: spinner + status (+ game name) on the left, percentage on the right, bar below ---
        double side = W * 0.06, bottom = H * 0.075;
        var strip = new Grid { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(side, 0, side, bottom) };
        strip.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        strip.RowDefinitions.Add(new RowDefinition { Height = new GridLength(H * 0.024) });
        strip.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(strip);

        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        strip.Children.Add(row);

        // spinner: thin ring with a fading tail in the accent colour
        double sz = H * 0.040, th = Math.Max(2.5, H / 320);
        var spin = new Grid { Width = sz, Height = sz, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, H * 0.022, 0) };
        spin.Children.Add(new Ellipse { Stroke = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255)), StrokeThickness = th });
        double rad = sz / 2 - th / 2, c = sz / 2;
        var fig = new PathFigure { StartPoint = new Point(c + rad, c), IsClosed = false };
        fig.Segments.Add(new ArcSegment(new Point(c, c - rad), new Size(rad, rad), 0, true, SweepDirection.Clockwise, true)); // 270 degrees
        var geo = new PathGeometry(); geo.Figures.Add(fig);
        var tail = new LinearGradientBrush { StartPoint = new Point(0, 1), EndPoint = new Point(1, 0) };
        tail.GradientStops.Add(new GradientStop(Color.FromArgb(0, accent.R, accent.G, accent.B), 0.0));
        tail.GradientStops.Add(new GradientStop(accent, 0.55));
        tail.GradientStops.Add(new GradientStop(Colors.White, 1.0));
        var arc = new System.Windows.Shapes.Path { Data = geo, Stroke = tail, StrokeThickness = th, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        var rot = new RotateTransform(0, c, c); arc.RenderTransform = rot;
        rot.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever });
        spin.Children.Add(arc);
        Grid.SetColumn(spin, 0); row.Children.Add(spin);

        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var status = new TextBlock { Text = Status, Foreground = Brushes.White, FontFamily = font, FontWeight = FontWeights.SemiBold, FontSize = Math.Max(16, H / 34), Effect = shadow(14) };
        texts.Children.Add(status);
        if (!string.IsNullOrEmpty(title))
            texts.Children.Add(new TextBlock { Text = title, Foreground = new SolidColorBrush(Color.FromArgb(150, 255, 255, 255)), FontFamily = font, FontSize = Math.Max(12, H / 56), Margin = new Thickness(0, H * 0.004, 0, 0), Effect = shadow(10) });
        Grid.SetColumn(texts, 1); row.Children.Add(texts);

        var percent = new TextBlock { Text = "", Foreground = Brushes.White, FontFamily = font, FontWeight = FontWeights.Light, FontSize = Math.Max(20, H / 20), VerticalAlignment = VerticalAlignment.Bottom, Effect = shadow(14), Opacity = 0 };
        Grid.SetColumn(percent, 2); row.Children.Add(percent);

        // progress bar: full width, accent gradient with a soft glow and a light sweeping across it
        double bw = W - side * 2, bh = Math.Max(4, H / 200);
        var track = new Grid { Height = bh, Width = bw, HorizontalAlignment = HorizontalAlignment.Left };
        track.Children.Add(new Border { CornerRadius = new CornerRadius(bh / 2), Background = new SolidColorBrush(Color.FromArgb(38, 255, 255, 255)) });
        var fillBox = new Grid { HorizontalAlignment = HorizontalAlignment.Left, Width = 0, ClipToBounds = true };
        var fillBrush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0) };
        fillBrush.GradientStops.Add(new GradientStop(accent, 0));
        fillBrush.GradientStops.Add(new GradientStop(Lighten(accent, 0.55), 1));
        fillBox.Children.Add(new Border { CornerRadius = new CornerRadius(bh / 2), Background = fillBrush });
        var shine = new Rectangle { Width = bw * 0.18, HorizontalAlignment = HorizontalAlignment.Left };
        var shineBrush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0) };
        shineBrush.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 0));
        shineBrush.GradientStops.Add(new GradientStop(Color.FromArgb(170, 255, 255, 255), 0.5));
        shineBrush.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 1));
        shine.Fill = shineBrush;
        var shineMove = new TranslateTransform(); shine.RenderTransform = shineMove;
        shineMove.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-bw * 0.2, bw, TimeSpan.FromSeconds(2.4)) { RepeatBehavior = RepeatBehavior.Forever });
        fillBox.Children.Add(shine);
        fillBox.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = accent, BlurRadius = 16, ShadowDepth = 0, Opacity = 0.9 };
        var fillMove = new TranslateTransform(); fillBox.RenderTransform = fillMove;
        track.Children.Add(fillBox);
        Grid.SetRow(track, 2); strip.Children.Add(track);

        // --- live updates: status crossfade, eased progress, moving bar while the time is unknown ---
        double shown = 0, marquee = 0; string pending = Status;
        var ui = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        ui.Tick += (s, e) =>
        {
            string want = Status;
            if (want != pending)
            {
                pending = want;
                var outA = new DoubleAnimation(status.Opacity, 0, TimeSpan.FromMilliseconds(160));
                outA.Completed += (a, b) =>
                {
                    status.Text = pending;
                    status.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
                };
                status.BeginAnimation(UIElement.OpacityProperty, outA);
            }
            float target = Progress;
            if (target >= 0)
            {
                shown += (target - shown) * 0.05;
                fillBox.Width = Math.Max(bh, bw * Math.Min(1, shown)); fillMove.X = 0;
                percent.Text = ((int)Math.Round(Math.Min(1, shown) * 100)) + "%";
                if (shown >= 0.01 && percent.Opacity < 1) percent.Opacity = Math.Min(1, percent.Opacity + 0.05);
            }
            else
            {
                marquee = (marquee + 0.006) % 1.0;
                double t = marquee < 0.5 ? 2 * marquee * marquee : 1 - Math.Pow(-2 * marquee + 2, 2) / 2;   // ease in-out
                fillBox.Width = bw * 0.22; fillMove.X = -bw * 0.22 + t * (bw * 1.22);
                percent.Opacity = 0;
            }
        };
        ui.Start();
        win.Show();
        root.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(400)));
        win.Activate();
    }
}
