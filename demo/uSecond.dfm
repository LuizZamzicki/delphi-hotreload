object FormSecond: TFormSecond
  Left = 0
  Top = 0
  Caption = 'Segunda tela'
  ClientHeight = 200
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  OnClose = FormClose
  TextHeight = 15
  object lblNome: TLabel
    Left = 24
    Top = 28
    Width = 36
    Height = 15
    Caption = 'Nome:'
  end
  object edtNome: TEdit
    Left = 24
    Top = 48
    Width = 312
    Height = 23
    TabOrder = 0
  end
  object chkAtivo: TCheckBox
    Left = 24
    Top = 88
    Width = 97
    Height = 17
    Caption = 'Ativo'
    TabOrder = 1
  end
  object btnOk: TButton
    Left = 260
    Top = 150
    Width = 75
    Height = 28
    Caption = 'OK'
    TabOrder = 2
    OnClick = btnOkClick
  end
end
