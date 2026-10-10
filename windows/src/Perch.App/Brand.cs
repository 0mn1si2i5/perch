using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Perch.Windows;
/// Uses the same three-bird paths and palette as Resources/AppIcon.svg.
public static class Brand
{
    /// `round` fills a circle instead of the app-icon squircle, for the native desktop orb.
    public static DrawingImage Image(bool round = false)
    {
        var bird = Geometry.Parse("M600 268 C656 268 694 306 694 360 L770 382 L692 404 C694 520 640 630 548 682 L430 770 L452 668 C418 596 428 468 498 380 C516 306 552 268 600 268 Z");
        var visual = new DrawingGroup();
        using (var c = visual.Open())
        {
            var fill = new LinearGradientBrush(Color.FromRgb(43, 53, 80), Color.FromRgb(18, 23, 37), 90);
            if (round)
                c.DrawEllipse(fill, null, new Point(512, 512), 412, 412);
            else
                c.DrawRoundedRectangle(fill, null, new Rect(100, 100, 824, 824), 185, 185);
            c.DrawLine(new Pen(new SolidColorBrush(Color.FromRgb(155, 165, 190)), 20), new Point(170, 676), new Point(854, 676));
            foreach (var (x, y, scale, color) in new[]
            {
                (-5d, 326d, .5, Color.FromRgb(159, 176, 207)),
                (439d, 326d, .5, Color.FromRgb(223, 230, 242)),
                (158d, 256d, .6, Color.FromRgb(241, 188, 91))
            }

            )
            {
                c.PushTransform(new MatrixTransform(scale, 0, 0, scale, x, y));
                c.DrawGeometry(new SolidColorBrush(color), null, bird);
                c.Pop();
            }
        }

        var image = new DrawingImage(visual);
        image.Freeze();
        return image;
    }

    public static System.Drawing.Icon TrayIcon()
    {
        var visual = new DrawingVisual();
        using (var c = visual.RenderOpen())
            c.DrawImage(Image(), new Rect(0, 0, 32, 32));
        var bitmap = new RenderTargetBitmap(32, 32, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        stream.Position = 0;
        using var drawing = new System.Drawing.Bitmap(stream);
        var handle = drawing.GetHicon();
        try
        {
            using var icon = System.Drawing.Icon.FromHandle(handle);
            return (System.Drawing.Icon)icon.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint handle);
}