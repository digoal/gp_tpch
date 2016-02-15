for i in `ls *.tbl`; do sed 's/|$//' $i > ${i/tbl/csv}; done
