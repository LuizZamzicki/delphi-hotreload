object TestForm: TTestForm
  Left = 0
  Top = 0
  Caption = 'Teste'
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
      Font.Style = [fsBold]
      ParentFont = False
    end
    object Button1: TButton
      Left = 16
      Top = 16
      Width = 75
      Height = 25
      Caption = 'Antes'
      TabOrder = 0
      OnClick = Button1Click
    end
  end
  object Panel2: TPanel
    Left = 200
    Top = 8
    Width = 185
    Height = 200
    TabOrder = 1
  end
  object Memo1: TMemo
    Left = 8
    Top = 216
    Width = 377
    Height = 73
    Lines.Strings = (
      'linha1')
    TabOrder = 2
  end
end
