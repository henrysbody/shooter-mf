namespace Kadr;

internal sealed class WelcomeWindow : Form
{
    private readonly Bitmap appImage;
    private readonly CheckBox startup;
    private static readonly Color Background = Color.FromArgb(24, 26, 34);
    private static readonly Color ShortcutColor = Color.FromArgb(192, 185, 255);
    private static readonly Color Secondary = Color.FromArgb(204, 208, 222);

    internal WelcomeWindow(Icon icon, Action capture, bool hotKeyAvailable)
    {
        Text = "Shooter MF";
        Icon = icon;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(500, 553);
        BackColor = Background;
        ForeColor = Color.White;
        appImage = icon.ToBitmap();

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(22, 12, 22, 14), ColumnCount = 1, RowCount = 5
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (int height in new[] { 63, 48, 42, 334 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(layout);

        var header = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) };
        header.Controls.Add(new PictureBox
        {
            Image = appImage, Size = new Size(48, 48), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 3, 12, 0)
        });
        header.Controls.Add(new Label
        {
            Text = "Shooter MF", Font = new Font(Font.FontFamily, 18, FontStyle.Bold), AutoSize = true,
            ForeColor = Color.White, Margin = new Padding(0, 11, 0, 0)
        });
        layout.Controls.Add(header, 0, 0);

        var button = new Button
        {
            Text = "Сделать скриншот", Dock = DockStyle.Fill, FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(88, 75, 217), ForeColor = Color.White, UseVisualStyleBackColor = false,
            Margin = new Padding(0, 0, 0, 8)
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => capture();
        AcceptButton = button;
        layout.Controls.Add(button, 0, 1);

        startup = new CheckBox
        {
            Text = "Запускать при старте системы", Dock = DockStyle.Fill, AutoCheck = false,
            ForeColor = Color.White, Margin = new Padding(0, 0, 0, 8)
        };
        startup.Click += (_, _) =>
        {
            try
            {
                WindowsIntegration.SetStartsAtLogin(!startup.Checked);
                RefreshStartup();
            }
            catch (Exception error) when (WindowsIntegration.IsRegistryError(error))
            {
                MessageBox.Show(this, "Не удалось изменить автозапуск.", "Shooter MF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        layout.Controls.Add(startup, 0, 2);

        (string Key, string Action)[] shortcuts =
        [
            (HotKeyWindow.Shortcut, "Сделать скриншот"), ("Ctrl+C / Ctrl+S", "Копировать / сохранить"),
            ("F", "Полный экран / предыдущая область"), ("T / S / R", "Текст / прямоугольник / овал"),
            ("E / A", "Линия / стрелка"), ("D / Q", "Карандаш / маркер"), ("1–7", "Цвет по порядку палитры"),
            ("+ / − / Tab", "Толщина кисти / размер текста"), ("Enter / Shift+Enter", "Завершить ввод / новая строка"),
            ("Shift", "Квадрат, круг или угол с шагом 45°"), ("Esc", "Отменить действие / закрыть редактор")
        ];
        var table = new TableLayoutPanel { Dock = DockStyle.Fill, Margin = new Padding(0), ColumnCount = 2, RowCount = shortcuts.Length };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int row = 0; row < shortcuts.Length; row++)
        {
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 29));
            table.Controls.Add(new Label { Text = shortcuts[row].Key, ForeColor = ShortcutColor,
                TextAlign = ContentAlignment.MiddleLeft, Dock = DockStyle.Fill, Margin = new Padding(0) }, 0, row);
            table.Controls.Add(new Label { Text = shortcuts[row].Action, ForeColor = Secondary,
                TextAlign = ContentAlignment.MiddleLeft, Dock = DockStyle.Fill, Margin = new Padding(0) }, 1, row);
        }
        layout.Controls.Add(table, 0, 3);
        if (!hotKeyAvailable)
        {
            layout.Controls.Add(new Label { Text = $"{HotKeyWindow.Shortcut} занято другим приложением.",
                ForeColor = Color.PeachPuff, Dock = DockStyle.Fill, Margin = new Padding(0) }, 0, 4);
        }
    }

    internal void RefreshStartup()
    {
        try { startup.Checked = WindowsIntegration.StartsAtLogin(); }
        catch (Exception error) when (WindowsIntegration.IsRegistryError(error)) { startup.Checked = false; }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) appImage.Dispose();
        base.Dispose(disposing);
    }
}
