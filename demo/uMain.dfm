object FormMain: TFormMain
  Left = 0
  Top = 0
  Caption = 'Hot Reload - demo'
  ClientHeight = 420
  ClientWidth = 640
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlTopo: TPanel
    Left = 0
    Top = 0
    Width = 640
    Height = 56
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblTitulo: TLabel
      Left = 16
      Top = 18
      Width = 266
      Height = 21
      Caption = 'Edite este form na IDE e salve (Ctrl+S)'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -16
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object btnSegunda: TButton
      Left = 480
      Top = 14
      Width = 144
      Height = 28
      Caption = 'Abrir segunda tela'
      TabOrder = 0
      OnClick = btnSegundaClick
    end
  end
  object memLog: TMemo
    Left = 0
    Top = 56
    Width = 640
    Height = 364
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 1
  end
end
