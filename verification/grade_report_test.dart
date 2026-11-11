import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../lib/services/grade_report_service.dart';
import '../server/lib/my_subjects/grading_calculator.dart';
Map<String,dynamic> fixture({int count=2,int quizzes=2}){
 final assessments=<Map<String,dynamic>>[];int id=0;
 for(final p in GradingCalculator.periods){
  for(final type in ['performance_task','laboratory',for(var i=0;i<quizzes;i++)'quiz','prelim']){
   id++;final cat=GradingCalculator.category(type)!;
   assessments.add({'id':id,'title':'$type assessment $id','assessment_type':type,'grading_period':p,'grading_category':cat,'creation_mode':cat=='pt'?'manual':'builder','grade_eligible':true,'column_label':'${cat=='quiz'?'Q':type=='laboratory'?'LAB':cat=='pt'?'PT':'EX'}$id','total_points':id%2==0?40:10});
  }
 }
 final students=<Map<String,dynamic>>[];
 for(var i=0;i<count;i++){
  final cells=[for(final a in assessments)<String,dynamic>{'exam_id':a['id'],'score':i==0?0:(a['total_points'] as num)*0.75,'max_score':a['total_points'],'status':'completed'}];
  final s=<String,dynamic>{'id':i+1,'student_number':'000${i+1}','first_name':'Student $i','last_name':'Dela Cruz','cells':cells};
  s['grading']=GradingCalculator.student(assessments,cells,GradingCalculator.defaults);students.add(s);
 }
 return {'assessments':assessments,'students':students,'preferences':GradingCalculator.defaults};
}
void main(){
 test('XLSX has five sheets, formulas, frozen columns and recorded zero',(){
  final b=fixture();final bytes=GradeReportService.xlsx(book:b,title:'OOP & Security',section:'BSIT41A');
  expect(bytes.take(2),[80,75]);final z=ZipDecoder().decodeBytes(bytes);final files={for(final f in z.files)f.name:f};
  for(final f in z.files.where((f)=>f.name.endsWith('.xml')||f.name.endsWith('.rels'))){expect(()=>XmlDocument.parse(utf8.decode(f.content)),returnsNormally,reason:f.name);}
  final workbook=XmlDocument.parse(utf8.decode(files['xl/workbook.xml']!.content));
  expect(workbook.findAllElements('sheet').map((s)=>s.getAttribute('name')).toList(),['Grade Summary','Prelims','Midterm','Pre-Finals','Finals']);
  final pre=XmlDocument.parse(utf8.decode(files['xl/worksheets/sheet2.xml']!.content));
  expect(pre.findAllElements('pane').single.getAttribute('xSplit'),'2');expect(pre.findAllElements('f').any((f)=>f.innerText.contains('COUNT(')&&f.innerText.contains('AVERAGE(')),isTrue);
  expect(pre.findAllElements('c').firstWhere((c)=>c.getAttribute('r')=='C5').findElements('v').single.innerText,'0');
  Directory('artifacts').createSync();File('artifacts/section.xlsx').writeAsBytesSync(bytes);File('artifacts/individual.xlsx').writeAsBytesSync(GradeReportService.xlsx(book:b,title:'OOP & Security',section:'BSIT41A',student:(b['students'] as List).last as Map<String,dynamic>));
 });
 test('unlimited columns cross Z and retain every assessment',(){final b=fixture(quizzes:35);final bytes=GradeReportService.xlsx(book:b,title:'Many assessments',section:'BSIT41A');final z=ZipDecoder().decodeBytes(bytes);final pre=XmlDocument.parse(utf8.decode(z.files.firstWhere((f)=>f.name=='xl/worksheets/sheet2.xml').content));expect(pre.findAllElements('c').any((c)=>c.getAttribute('r')=='AA5'),isTrue);expect(pre.findAllElements('t').where((e)=>e.innerText.contains('quiz assessment')).length,35);});
 test('PDF exports support individual layout and large sections',()async{
  final small=fixture();final individual=await GradeReportService.pdf(book:small,title:'OOP & Security',section:'BSIT41A',fontRegular:File('../assets/fonts/CheckMateGrades-Regular.ttf').readAsBytesSync(),fontBold:File('../assets/fonts/CheckMateGrades-Bold.ttf').readAsBytesSync(),student:(small['students'] as List).last as Map<String,dynamic>);
  expect(ascii.decode(individual.take(5).toList()),'%PDF-');File('artifacts/individual.pdf').writeAsBytesSync(individual);
  final big=fixture(count:55,quizzes:10);final section=await GradeReportService.pdf(book:big,title:'OOP & Security',section:'BSIT41A',fontRegular:File('../assets/fonts/CheckMateGrades-Regular.ttf').readAsBytesSync(),fontBold:File('../assets/fonts/CheckMateGrades-Bold.ttf').readAsBytesSync());expect(section.length,greaterThan(10000));File('artifacts/section.pdf').writeAsBytesSync(section);
 });
}
