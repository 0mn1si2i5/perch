using System.Windows;
using System.Windows.Controls;

namespace Perch.Windows;

public partial class HandoffCard : UserControl
{
    public HandoffCard()
    {
        InitializeComponent();
    }

    private void PendingMenu(object sender, RoutedEventArgs e) => ViewMenus.Pending((Button)sender);
}