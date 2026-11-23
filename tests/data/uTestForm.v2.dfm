object TestForm: TTestForm
  Left = 0
  Top = 0
  Caption = 'Teste v2'
  ClientHeight = 300
  ClientWidth = 400
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object Panel1: TPanel
    Left = 8
    Top = 8
    Width = 185
    Height = 200
    Color = clRed
    ParentBackground = False
    TabOrder = 0
    object Label1: TLabel
      Left = 16
      Top = 56
      Width = 40
      Height = 15
      Caption = 'R'#243'tulo'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      ParentFont = False
    end
  end
  object Panel2: TPanel
    Left = 200
    Top = 8
    Width = 185
    Height = 200
    TabOrder = 1
    object Button1: TButton
      Left = 24
      Top = 24
      Width = 75
      Height = 25
      Caption = 'Depois'
      TabOrder = 0
      OnClick = Button2Click
    end
    object Label2: TLabel
      Left = 24
      Top = 72
      Width = 30
      Height = 15
      Caption = 'Nova'
    end
    object CheckBox1: TCheckBox
      Left = 24
      Top = 100
      Width = 97
      Height = 17
      Caption = 'Marque'
      TabOrder = 1
    end
  end
end
