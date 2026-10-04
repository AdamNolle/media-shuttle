using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace MediaShuttle;

internal static class ToggleSwitchAppearance
{
    // Change only the native template's geometry; keep its input, accessibility and animations.
    internal static void UseSquareCorners(ToggleSwitch toggle)
    {
        toggle.Loaded += (_, _) => ApplySquareCorners(toggle);
        toggle.ActualThemeChanged += (_, _) => ApplySquareCorners(toggle);
        toggle.RegisterPropertyChangedCallback(Control.TemplateProperty,
            (_, _) => toggle.DispatcherQueue.TryEnqueue(() => ApplySquareCorners(toggle)));
    }

    private static void ApplySquareCorners(ToggleSwitch toggle)
    {
        toggle.ApplyTemplate();
        SquareTemplateParts(toggle);
    }

    private static void SquareTemplateParts(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is Rectangle rectangle &&
                rectangle.Name is "OuterBorder" or "SwitchKnobBounds" or "SwitchKnobOff")
            {
                rectangle.RadiusX = 0;
                rectangle.RadiusY = 0;
            }
            else if (child is Border { Name: "SwitchKnobOn" } knob)
            {
                knob.CornerRadius = new CornerRadius(0);
            }
            SquareTemplateParts(child);
        }
    }
}
