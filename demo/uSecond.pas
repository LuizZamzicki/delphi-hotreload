unit uSecond;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls;

type
  TFormSecond = class(TForm)
    lblNome: TLabel;
    edtNome: TEdit;
    chkAtivo: TCheckBox;
    btnOk: TButton;
    procedure btnOkClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  end;

implementation

{$R *.dfm}

procedure TFormSecond.btnOkClick(Sender: TObject);
begin
  ShowMessage('Olá, ' + edtNome.Text);
end;

procedure TFormSecond.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree;
end;

end.
